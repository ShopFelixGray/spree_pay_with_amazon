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
  class AmazonTransaction < ActiveRecord::Base
    has_many :payments, :as => :source

    scope :unsuccessful, -> { where(success: false) }

    def name
      "Pay with Amazon"
    end

    def cc_type
      "n/a"
    end

    def display_number
      "n/a"
    end

    def month
      "n"
    end

    def year
      "a"
    end

    def reusable_sources(_order)
      []
    end

    def self.with_payment_profile
      []
    end

    def can_capture?(payment)
      (payment.pending? || payment.checkout?) && payment.amount > 0
    end

    def can_credit?(payment)
      payment.completed? && payment.credit_allowed > 0
    end

    def can_void?(payment)
      payment.pending?
    end

    def can_close?(payment)
      payment.completed? && closed_at.nil?
    end

    def actions
      %w{capture credit void close}
    end

    def close!(payment)
      return true unless can_close?(payment)

      amazon_order = SpreeAmazon::Order.new(
        gateway: payment.payment_method,
        reference_id: order_reference
      )

      response = amazon_order.close_order_reference!

      if response.success?
        update_attributes(closed_at: DateTime.now)
      else
        gateway_error(response)
      end
    end

    private

    def gateway_error(error)
      text = error.params['message'] || error.params['response_reason_text'] || error.message

      logger.error(Spree.t(:gateway_error))
      logger.error("  #{error.to_yaml}")

      raise Spree::Core::GatewayError.new(text)
    end

  end
end
