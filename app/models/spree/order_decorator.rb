##
# Amazon Payments - Login and Pay for Spree Commerce
#
# @category    Amazon
# @package     Amazon_Payments
# @copyright   Copyright (c) 2014 Amazon.com
# @license     http://opensource.org/licenses/Apache-2.0  Apache License, Version 2.0
#
##
Spree::Order.class_eval do
  has_many :amazon_transactions

  alias_method :spree_confirmation_required?, :confirmation_required?
  alias_method :spree_assign_default_credit_card, :assign_default_credit_card

  def amazon_transaction
    amazon_transactions.last
  end

  def amazon_order_reference_id
    amazon_transaction.try(:order_reference)
  end

  def amazon_pay_order?
    amazon_transaction.try(:success)
  end

  def confirmation_required?
    spree_confirmation_required? || payments.valid.map(&:payment_method).compact.any? { |pm| pm.is_a? Spree::Gateway::Amazon }
  end

  def assign_default_credit_card
    return if payments.valid.amazon.count > 0
    spree_assign_default_credit_card
  end
end