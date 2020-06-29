##
# Amazon Payments - Login and Pay for Spree Commerce
#
# @category    Amazon
# @package     Amazon_Payments
# @copyright   Copyright (c) 2014 Amazon.com
# @license     http://opensource.org/licenses/Apache-2.0  Apache License, Version 2.0
#
##
class Spree::AmazonpayController < Spree::CheckoutController
  before_action :gateway

  skip_before_action :verify_authenticity_token, only: %i[create complete]

  rescue_from ActiveRecord::RecordInvalid, with: :rescue_from_active_record_error

  respond_to :json

  def create
    params = { webCheckoutDetail:
              { checkoutReviewReturnUrl: confirm_amazonpay_url },
               storeId: gateway.preferred_client_id }

    response = AmazonPay::CheckoutSession.create(params)

    if response.success?
      render json: response.body
    else
      render json: {}
    end
  end

  def confirm
    response = AmazonPay::CheckoutSession.get(amazon_checkout_session_id)

    unless response.success?
      redirect_to cart_path, notice: Spree.t(:order_processed_unsuccessfully)
      return
    end

    body = response.body
    status_detail = body[:statusDetail]
    no_buyer = response.find_constraint('BuyerNotAssociated')

    # if the order was already completed then they shouldn't be at this step
    if status_detail[:state] == 'Completed' || no_buyer
      redirect_to cart_path, notice: Spree.t(:order_processed_unsuccessfully)
      return
    end

    amazon_user = SpreeAmazon::User.from_response(body)

    unless amazon_user.valid?
      redirect_to cart_path, notice: Spree.t(:uid_not_set)
      return
    end

    set_user_information(amazon_user.auth_hash)

    if spree_current_user.nil?
      @order.update_attributes!(email: amazon_user.email)
    end

    amazon_address = SpreeAmazon::Address.from_response(body)
    address_attributes = amazon_address.attributes

    if spree_address_book_available?
      address_attributes = address_attributes.merge(user: spree_current_user)
    end

    if address_restrictions(amazon_address)
      redirect_to cart_path, notice: Spree.t(:cannot_ship_to_address)
      return
    end

    update_order_address!(address_attributes)
    update_order_state('address')

    @order.unprocessed_payments.map(&:invalidate!)

    if !order_next || @order.shipments.empty?
      redirect_to cart_path, notice: Spree.t(:cannot_ship_to_address)
    else
      order_next
    end
  end

  def payment
    update_order_state('payment')

    unless order_next
      flash[:error] = @order.errors.full_messages.join("\n")
      redirect_to cart_path
      return
    end

    params = {
      webCheckoutDetail: {
        checkoutResultReturnUrl: complete_amazonpay_url
      },
      paymentDetail: {
        paymentIntent: 'Authorize',
        canHandlePendingAuthorization: false,
        chargeAmount: {
          amount: @order.order_total_after_store_credit,
          currencyCode: current_currency
        }
      },
      merchantMetadata: {
        merchantReferenceId: @order.number,
        merchantStoreName: current_store.name,
        noteToBuyer: '',
        customInformation: ''
      }
    }

    response = AmazonPay::CheckoutSession.update(amazon_checkout_session_id, params)

    if response.success?
      web_checkout_detail = response.body[:webCheckoutDetail]
      redirect_to web_checkout_detail[:amazonPayRedirectUrl]
    else
      redirect_to cart_path, notice: Spree.t(:order_processed_unsuccessfully)
    end
  end

  def complete
    response = AmazonPay::CheckoutSession.get(amazon_checkout_session_id)

    unless response.success?
      redirect_to cart_path, notice: Spree.t(:order_processed_unsuccessfully)
      return
    end

    body = response.body
    status_detail = body[:statusDetail]

    # Make sure the order status from Amazon is completed otherwise
    # Redirect to cart for the consumer to start over
    unless status_detail[:state] == 'Completed'
      redirect_to cart_path, notice: status_detail[:reasonDescription]
      return
    end

    payments = @order.payments
    payment = payments.create
    payment.payment_method = gateway
    payment.source ||= Spree::AmazonTransaction.create(
      order_reference: body[:chargePermissionId],
      order_id: @order.id,
      capture_id: body[:chargeId],
      retry: false
    )
    payment.amount = @order.order_total_after_store_credit
    payment.response_code = body[:chargeId]
    payment.save!

    @order.reload

    while order_next; end

    if @order.complete?
      @current_order = nil
      flash.notice = Spree.t(:order_processed_successfully)
      flash[:order_completed] = true
      redirect_to completion_route
    else
      update_order_state('cart')
      amazon_transaction = @order.amazon_transaction
      amazon_transaction.reload
      unless amazon_transaction.soft_decline
        @order.amazon_transactions.destroy_all
        @order.temporary_address = true
        @order.save!
      end
      redirect_to cart_path, notice: Spree.t(:order_processed_unsuccessfully)
    end
  end

  def gateway
    @gateway ||= Spree::Gateway::Amazon.for_currency(@order.currency)
    @gateway.load_amazon_pay
    @gateway
  end

  private

  def update_order_state(state)
    if @order.state != state
      @order.temporary_address = true
      @order.state = state
      @order.save!
    end
  end

  def amazon_checkout_session_id
    params[:amazonCheckoutSessionId]
  end

  # Override this function if you need to restrict shipping locations
  def address_restrictions(amazon_address)
    amazon_address.nil?
  end

  def set_user_information(auth_hash)
    return unless Gem::Specification.find_all_by_name('spree_social').any? && auth_hash

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

    @order.associate_user!(user)
    session[:guest_token] = nil
  end

  def update_order_address!(address_attributes)
    ship_address = @order.ship_address
    bill_address = @order.bill_address

    new_address = Spree::Address.new address_attributes
    if spree_current_user.respond_to?(:addresses)
      user_address = spree_current_user.addresses.find do |address|
        address.same_as?(new_address)
      end

      if user_address
        @order.update_column(:ship_address_id, user_address.id)
        @order.update_column(:bill_address_id, user_address.id)
      else
        new_address.save!
        @order.update_column(:ship_address_id, new_address.id)
        @order.update_column(:bill_address_id, new_address.id)
      end
    elsif ship_address.nil? || ship_address.empty?
      new_address.save!
      @order.update_column(:ship_address_id, new_address.id)
      @order.update_column(:bill_address_id, new_address.id)
    else
      ship_address.update_attributes(address_attributes)
      bill_address.update_attributes(address_attributes)
    end
  end

  def rescue_from_spree_gateway_error(exception)
    flash.now[:error] = Spree.t(:spree_gateway_error_flash_for_checkout)
    @order.errors.add(:base, exception.message)
    render :confirm
  end

  def rescue_from_active_record_error(exception)
    flash.now[:error] = Spree.t(:spree_active_record_error_flash_for_checkout)
    @order.errors.add(:base, exception.message)
    render :confirm
  end

  def skip_state_validation?
    true
  end

  # We are logging the user in so there is no need to check registration
  def check_registration
    true
  end

  def order_next
    @order.temporary_address = true
    @order.next
  end

  def spree_address_book_available?
    Gem::Specification.find_all_by_name('spree_address_book').any?
  end
end
