##
# Amazon Payments - Login and Pay for Spree Commerce
#
# @category    Amazon
# @package     Amazon_Payments
# @copyright   Copyright (c) 2014 Amazon.com
# @license     http://opensource.org/licenses/Apache-2.0  Apache License, Version 2.0
#
##
module Spree
  class Gateway::Amazon < Gateway
    REGIONS = %w[us uk de jp].freeze

    preference :currency, :string, default: -> { Spree::Config.currency }
    preference :client_id, :string
    preference :merchant_id, :string
    preference :aws_access_key_id, :string
    preference :aws_secret_access_key, :string
    preference :region, :string, default: 'us'
    preference :site_domain, :string
    preference :public_key_id, :string
    preference :private_key_file_location, :string

    has_one :provider

    validates :preferred_region, inclusion: { in: REGIONS }

    def self.for_currency(currency)
      where(active: true).detect { |gateway| gateway.preferred_currency == currency }
    end

    def widgets_url
      {
        'us' => 'https://static-na.payments-amazon.com/checkout.js',
        'uk' => 'https://static-eu.payments-amazon.com/checkout.js',
        'de' => 'https://static-eu.payments-amazon.com/checkout.js',
        'jp' => 'https://static-fe.payments-amazon.com/checkout.js'
      }.fetch(preferred_region)
    end

    def supports?(source)
      true
    end

    def method_type
      'amazon'
    end

    def provider_class
      AmazonTransaction
    end

    def payment_source_class
      AmazonTransaction
    end

    def source_required?
      true
    end

    def authorize(amount, amazon_transaction, gateway_options={})
      return ActiveMerchant::Billing::Response.new(true, 'Success', {}) if amount < 0

      # If there already is a capture_id available then we don't need to create
      # a charage and can immediately capture
      if amazon_transaction.try(:capture_id)
        return capture(amount, amazon_transaction.capture_id, gateway_options)
      end

      load_amazon_pay

      params = {
        chargePermissionId: amazon_transaction.order_reference,
        chargeAmount: {
          amount: (amount / 100.0).to_s,
          currencyCode: gateway_options[:currency]
        },
        captureNow: false,
        canHandlePendingAuthorization: false
      }

      response = AmazonPay::Charge.create(params)

      success = response.success?
      message = response.message[0..255]

      # Saving information in last amazon transaction for error flow in amazon controller
      amazon_transaction.update!(
        success: success,
        message: message,
        capture_id: response.body[:chargeId],
        soft_decline: response.soft_decline?,
        retry: !success
      )

      ActiveMerchant::Billing::Response.new(success, message, response.body)
    end

    def capture(amount, response_code, gateway_options={})
      return credit(amount.abs, response_code, gateway_options) if amount < 0

      _payment, amazon_transaction = find_payment_and_transaction(response_code)

      load_amazon_pay

      params = {
        captureAmount: {
          amount: (amount / 100.0).to_s,
          currencyCode: gateway_options[:currency]
        },
        softDescriptor: Spree::Store.current.try(:name)
      }

      capture_id = update_for_backwards_compatibility(amazon_transaction.capture_id)

      response = AmazonPay::Charge.capture(capture_id, params)

      success = response.success?
      message = response.message[0..255]

      # Saving information in last amazon transaction for error flow in amazon controller
      amazon_transaction.update!(
        success: success,
        message: message,
        soft_decline: response.soft_decline?,
        retry: !success
      )

      ActiveMerchant::Billing::Response.new(success, message)
    end

    def purchase(amount, amazon_transaction, gateway_options = {})
      capture(amount, amazon_transaction.capture_id, gateway_options)
    end

    def credit(amount, response_code, _gateway_options = {})
      payment, amazon_transaction = find_payment_and_transaction(response_code)

      load_amazon_pay

      capture_id = update_for_backwards_compatibility(amazon_transaction.capture_id)

      params = {
        chargeId: capture_id,
        refundAmount: {
          amount: (amount / 100.0).to_s,
          currencyCode: payment.currency
        },
        softDescriptor: Spree::Store.current.try(:name)
      }

      response = AmazonPay::Refund.create(params)

      authorization = response.success? ? response.body[:refundId] : nil

      ActiveMerchant::Billing::Response.new(response.success?,
                                            response.message[0...255],
                                            response.body,
                                            authorization: authorization)
    end

    def void(response_code, _gateway_options = {})
      cancel(response_code)
    end

    def cancel(response_code)
      payment, amazon_transaction = find_payment_and_transaction(response_code)

      if amazon_transaction.capture_id.nil?
        load_amazon_pay
        params = { cancellationReason: 'Cancelled Order' }
        response = AmazonPay::Charge.cancel(amazon_transaction.order_reference,
                                            params)

        ActiveMerchant::Billing::Response.new(response.success?,
                                              response.message[0...255])
      else
        credit(payment.credit_allowed * 100, response_code)
      end
    end

    def load_amazon_pay
      AmazonPay.region = preferred_region
      AmazonPay.public_key_id = preferred_public_key_id
      AmazonPay.sandbox = preferred_test_mode
      AmazonPay.private_key = preferred_private_key_file_location
    end

    private

    def find_payment_and_transaction(response_code)
      payment = Spree::Payment.find_by(response_code: response_code)
      (raise Spree::Core::GatewayError, 'Payment not found') unless payment
      amazon_transaction = payment.source
      [payment, amazon_transaction]
    end

    def update_for_backwards_compatibility(capture_id)
      capture_id[20] == 'A' ? capture_id[20, 1] = 'C' : capture_id
    end
  end
end
