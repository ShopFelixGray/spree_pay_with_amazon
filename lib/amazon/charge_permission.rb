module AmazonPay
  class ChargePermission
    def self.get(charge_permission_id)
      AmazonPay.request('get', "chargePermissions/#{charge_permission_id}")
    end

    def self.update(charge_permission_id, params)
      AmazonPay.request('patch', "chargePermissions/#{charge_permission_id}", params)
    end

    def self.close(charge_permission_id, params)
      AmazonPay.request('delete', "chargePermissions/#{charge_permission_id}/close", params)
    end
  end
end
