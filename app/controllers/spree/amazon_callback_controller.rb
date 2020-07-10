##
# Amazon Payments - Login and Pay for Spree Commerce
#
# @category    Amazon
# @package     Amazon_Payments
# @copyright   Copyright (c) 2014 Amazon.com
# @license     http://opensource.org/licenses/Apache-2.0  Apache License, Version 2.0
#
##
class Spree::AmazonCallbackController < ApplicationController
  skip_before_action :verify_authenticity_token

  # This is the body that is sent from Amazon's IPN
  #
  # {
  #  "merchantId": "Relevant Merchant for the notification",
  #  "objectType": "one of: Charge, Refund",
  #  "objectId": "Id of relevant object",
  #  "notificationType": "STATE_CHANGE",
  #  "notificationId": "Randomly generated Id, used for tracking only",
  #  "notificationVersion": "V1"
  # }

  def new
    response = JSON.parse(response.body, symbolize_names: true)
    if response[:objectType] == 'Refund'
      refund_id = response[:objectId]
      payment = Spree::LogEntry.where('details LIKE ?', "%#{refund_id}%").last.try(:source)
      if payment
        l = payment.log_entries.build(details: response)
        l.save
      end
    end
    head :ok
  end
end
