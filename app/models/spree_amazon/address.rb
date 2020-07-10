module SpreeAmazon
  class Address
    class << self
      def from_response(response)
        new attributes_from_response(response[:shippingAddress])
      end

      def attributes_from_response(address_params)
        @attributes = {
          address1: address_params[:addressLine1],
          address2: address_params[:addressLine2],
          first_name: convert_first_name(address_params[:name]) || 'Amazon',
          last_name: convert_last_name(address_params[:name]) || 'User',
          city: address_params[:city],
          zipcode: address_params[:postalCode],
          state: convert_state(address_params[:stateOrRegion],
                               convert_country(address_params[:countryCode])),
          country: convert_country(address_params[:countryCode]),
          phone: convert_phone(address_params[:phoneNumber]) || '0000000000'
        }
      end

      def attributes
        @attributes
      end

      private

      def convert_first_name(name)
        return nil if name.blank?
        name.split(' ').first
      end

      def convert_last_name(name)
        return nil if name.blank?
        names = name.split(' ')
        names.shift
        names = names.join(' ')
        names.blank? ? nil : names
      end

      def convert_country(country_code)
        Spree::Country.find_by(iso: country_code)
      end

      def convert_state(state_name, country)
        Spree::State.find_by(abbr: state_name, country: country) ||
          Spree::State.find_by(name: state_name, country: country)
      end

      def convert_phone(phone_number)
        return nil if phone_number.blank? ||
                      phone_number.length < 10 ||
                      phone_number.length > 15
        phone_number
      end
    end

    attr_accessor :first_name, :last_name, :city, :zipcode,
                  :state, :country, :address1, :address2, :phone

    def initialize(attributes)
      attributes.each_pair do |key, value|
        send("#{key}=", value)
      end
    end

    def attributes
      self.class.attributes
    end
  end
end
