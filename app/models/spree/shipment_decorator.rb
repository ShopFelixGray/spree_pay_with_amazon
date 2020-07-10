Spree::Shipment.class_eval do
  delegate :amazon_pay_order?, to: :order

  self.state_machine.after_transition(
    to: :shipped,
    do: :alexa_delivery_notification,
    if: :send_alexa_delivery_notification?
  )

  def send_alexa_delivery_notification?
    amazon_pay_order? && amazon_carrier_code.present? && tracking.present?
  end

  def alexa_delivery_notification
    AlexaDeliveryNotificationJob.set(wait: 2.seconds).perform_later(id)
  end

  # override this if your carrier codes don't match amazon carrier codes
  # https://eps-eu-external-file-share.s3.eu-central-1.amazonaws.com/Alexa/Delivery+Notifications/amazon-pay-delivery-tracker-supported-carriers-v2.csv
  def amazon_carrier_code
    shipping_method.try(:code)
  end
end
