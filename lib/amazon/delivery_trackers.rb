module AmazonPay
  class DeliveryTrackers
    def self.create(params)
      AmazonPay.request('post', 'deliveryTrackers', params)
    end
  end
end
