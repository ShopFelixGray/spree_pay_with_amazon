module AmazonPay
  class Refund
    def self.create(params)
      AmazonPay.request('post', 'refunds', params)
    end

    def self.get(refund_id)
      AmazonPay.request('get', "refunds/#{refund_id}")
    end
  end
end
