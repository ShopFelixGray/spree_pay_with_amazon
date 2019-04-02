##
# Amazon Payments - Login and Pay for Spree Commerce
#
# @category    Amazon
# @package     Amazon_Payments
# @copyright   Copyright (c) 2014 Amazon.com
# @license     http://opensource.org/licenses/Apache-2.0  Apache License, Version 2.0
#
##
class Spree::AmazonController < Spree::StoreController
  helper 'spree/orders'
  before_action :check_current_order
  before_action :gateway, only: [:address, :payment, :delivery]
  before_action :check_amazon_reference_id, only: [:delivery, :complete]
  before_action :normalize_addresses, only: [:address, :delivery]
  skip_before_action :verify_authenticity_token, only: %i[payment confirm complete]

  respond_to :json

  def address
    set_user_information!

    if current_order.cart?
      current_order.next!
    else
      current_order.state = 'address'
      current_order.save!
    end
  end

  def payment
    payment = amazon_payment || current_order.payments.create
    payment.payment_method = gateway
    payment.source ||= Spree::AmazonTransaction.create(
      order_reference: params[:order_reference],
      order_id: current_order.id,
      retry: current_order.amazon_transactions.unsuccessful.any?
    )

    payment.save!

    render json: {}
  end

  def delivery
    address = SpreeAmazon::Address.find(
      current_order.amazon_order_reference_id,
      gateway: gateway,
      address_consent_token: access_token
    )

    current_order.state = 'address'

    if address
      current_order.email = current_order.email || spree_current_user.try(:email) || "pending@amazon.com"
      update_current_order_address!(address, spree_current_user.try(:ship_address))

      current_order.save!
      current_order.next

      current_order.reload

      if current_order.shipments.empty?
        render plain: 'Not shippable to this address'
      else
        render layout: false
      end
    else
      head :ok
    end
  end

  def confirm
    if amazon_payment.present? && current_order.update_from_params(params, permitted_checkout_attributes, request.headers.env)
      while !current_order.confirm? && current_order.next
      end

      update_payment_amount!
      current_order.next! unless current_order.confirm?
      complete
    else
      redirect_to :back
    end
  end

  def complete
    @order = current_order
    authorize!(:edit, @order, cookies.signed[:guest_token])

    unless @order.amazon_transaction.retry
      amazon_response = set_order_reference_details!
      unless amazon_response.constraints.blank?
        redirect_to address_amazon_order_path, notice: amazon_response.constraints and return
      end
    end

    complete_amazon_order!

    if @order.confirm? && @order.next
      @order.update_column(:bill_address, @order.ship_address_id)
      @current_order = nil
      flash.notice = Spree.t(:order_processed_successfully)
      flash[:order_completed] = true
      redirect_to spree.order_path(@order)
    else
      amazon_transaction = @order.amazon_transaction
      @order.state = 'cart'
      amazon_transaction.reload
      if amazon_transaction.soft_decline
        @order.save!
        redirect_to address_amazon_order_path, notice: amazon_transaction.message
      else
        @order.amazon_transactions.destroy_all
        @order.save!
        redirect_to cart_path, notice: Spree.t(:order_processed_unsuccessfully)
      end
    end
  end

  def gateway
    @gateway ||= Spree::Gateway::Amazon.for_currency(current_order.currency)
  end

  private

  def access_token
    params[:access_token]
  end

  def amazon_order
    @amazon_order ||= SpreeAmazon::Order.new(
      reference_id: current_order.amazon_order_reference_id,
      gateway: gateway,
    )
  end

  def amazon_payment
    current_order.payments.valid.amazon.first
  end

  def update_payment_amount!
    payment = amazon_payment
    payment.amount = current_order.order_total_after_store_credit
    payment.save!
  end

  def set_order_reference_details!
    amazon_order.set_order_reference_details(
        current_order.order_total_after_store_credit,
        seller_order_id: current_order.number,
        store_name: current_order.store.name,
      )
  end

  def set_user_information!
    return unless Gem::Specification::find_all_by_name('spree_social').any? && access_token

    auth_hash = SpreeAmazon::User.find(gateway: gateway,
      access_token: access_token)

    return unless auth_hash

    authentication = Spree::UserAuthentication.find_by_provider_and_uid(auth_hash['provider'], auth_hash['uid'])

    if authentication.present? && authentication.try(:user).present?
      user = authentication.user
      sign_in(user, scope: :spree_user)
    elsif spree_current_user
      spree_current_user.apply_omniauth(auth_hash)
      spree_current_user.save!
      user = spree_current_user
    else
      email = auth_hash['info']['email']
      user = Spree::User.find_by_email(email) || Spree::User.new
      user.apply_omniauth(auth_hash)
      user.save!
      sign_in(user, scope: :spree_user)
    end

    # make sure to merge the current order with signed in user previous cart
    set_current_order

    current_order.associate_user!(user)
    session[:guest_token] = nil
  end

  def complete_amazon_order!
    amazon_order.confirm
  end

  def checkout_params
    params.require(:order).permit(permitted_checkout_attributes)
  end

  def update_current_order_address!(amazon_address, spree_user_address = nil)
    bill_address = current_order.bill_address
    ship_address = current_order.ship_address

    new_address = Spree::Address.new address_attributes(amazon_address, spree_user_address)
    if spree_address_book_available?
      user_address = spree_current_user.addresses.find do |address|
        address.same_as?(new_address)
      end

      if user_address
        current_order.update_column(:ship_address_id, user_address.id)
        current_order.update_column(:bill_address_id, user_address.id)
      else
        new_address.save!
        current_order.update_column(:ship_address_id, new_address.id)
        current_order.update_column(:bill_address_id, new_address.id)
      end
    else
      if ship_address.nil? || ship_address.empty?
        new_address.save!
        current_order.update_column(:ship_address_id, new_address.id)
        current_order.update_column(:bill_address_id, new_address.id)
      else
        ship_address.update_attributes(address_attributes(amazon_address, spree_user_address))
      end
    end
  end

  def address_attributes(amazon_address, spree_user_address = nil)
    address_params = {
      firstname: amazon_address.first_name || spree_user_address.try(:first_name) || "Amazon",
      lastname: amazon_address.last_name || spree_user_address.try(:last_name) || "User",
      address1: amazon_address.address1 || spree_user_address.try(:address1) || "N/A",
      address2: amazon_address.address2,
      phone: amazon_address.phone || spree_user_address.try(:phone) || "000-000-0000",
      city: amazon_address.city || spree_user_address.try(:city),
      zipcode: amazon_address.zipcode || spree_user_address.try(:zipcode),
      state: amazon_address.state || spree_user_address.try(:state),
      country: amazon_address.country || spree_user_address.try(:country)
    }

    if spree_address_book_available?
      address_params = address_params.merge(user: spree_current_user)
    end

    address_params
  end

  def check_current_order
    unless current_order
      head :ok
    end
  end

  def check_amazon_reference_id
    unless current_order.amazon_order_reference_id
      head :ok
    end
  end

  def spree_address_book_available?
    Gem::Specification::find_all_by_name('spree_address_book').any?
  end

  def normalize_addresses
    # ensure that there is no validation errors and addresses were saved
    return unless current_order.bill_address && current_order.ship_address && spree_address_book_available?

    bill_address = current_order.bill_address
    ship_address = current_order.ship_address
    if current_order.bill_address_id != current_order.ship_address_id && bill_address.same_as?(ship_address)
      current_order.update_column(:bill_address_id, ship_address.id)
      bill_address.destroy
    else
      bill_address.update_attribute(:user_id, spree_current_user.try(:id))
    end

    ship_address.update_attribute(:user_id, spree_current_user.try(:id))
  end
end
