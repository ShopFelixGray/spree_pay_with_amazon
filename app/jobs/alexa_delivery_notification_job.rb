class AlexaDeliveryNotificationJob < ActiveJob::Base
  queue_as :default

  def perform(shipment_id)
    shipment = Spree::Shipment.find_by(id: shipment_id)
    order = shipment.order

    params = {
      amazonOrderReferenceId: order.amazon_order_reference_id,
      deliveryDetails: [{
        trackingNumber: shipment.tracking,
        carrierCode: shipment.amazon_carrier_code
      }]
    }

    # need to do this to make sure everything loads
    Spree::Gateway::Amazon.for_currency(order.currency).load_amazon_pay

    response = AmazonPay::DeliveryTrackers.create(params)

    raise 'Could not update tracking info for Alexa DN' unless response.success?
  end
end
