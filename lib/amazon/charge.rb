module AmazonPay
  class Charge
    def self.create(params)
      AmazonPay.request('post', 'charges', params)
    end

    def self.get(charge_id)
      AmazonPay.request('get', "charges/#{charge_id}")
    end

    def self.capture(charge_id, params)
      AmazonPay.request('post', "charges/#{charge_id}/capture", params)
    end

    def self.cancel(charge_id, params)
      AmazonPay.request('delete', "charges/#{charge_id}/cancel", params)
    end
  end
end
