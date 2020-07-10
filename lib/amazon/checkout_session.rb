module AmazonPay
  class CheckoutSession
    def self.create(params)
      AmazonPay.request('post', 'checkoutSessions', params)
    end

    def self.get(checkout_session_id)
      AmazonPay.request('get', "checkoutSessions/#{checkout_session_id}")
    end

    def self.update(checkout_session_id, params)
      AmazonPay.request('patch', "checkoutSessions/#{checkout_session_id}", params)
    end
  end
end
