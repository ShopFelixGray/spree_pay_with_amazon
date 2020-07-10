##
# Amazon Payments - Login and Pay for Spree Commerce
#
# @category    Amazon
# @package     Amazon_Payments
# @copyright   Copyright (c) 2014 Amazon.com
# @license     http://opensource.org/licenses/Apache-2.0  Apache License, Version 2.0
#
##
Spree::Core::Engine.routes.draw do
  resource :amazonpay, only: [], controller: 'amazonpay' do
    member do
      post 'create'
      get  'confirm'
      post 'delivery'
      post 'payment'
      post 'complete'
      get  'complete'
    end
  end

  post 'amazon_callback', to: 'amazon_callback#new'
  get 'amazon_callback', to: 'amazon_callback#new'
end
