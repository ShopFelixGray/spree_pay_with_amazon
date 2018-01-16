class SpreeAmazon::Response
  attr_reader :type, :response

  def initialize(response)
    @type = self.class.name.demodulize
    @response = response
  end

  def fetch(path, element)
    response.get_element(path, element)
  end

  def response_details
    "#{@type}Response/#{@type}Result/#{@type}Details"
  end

  def response_id
    fetch("#{response_details}", "Amazon#{@type}Id")
  end

  def reference_id
    fetch("#{response_details}", "#{@type}ReferenceId")
  end

  def amount
    fetch("#{response_details}/#{@type}Amount", "Amount")
  end

  def currency_code
    fetch("#{response_details}/#{@type}Amount", "CurrencyCode")
  end

  def state
    fetch("#{response_details}/#{@type}Status", "State")
  end

  def success_state?
    %w{Pending Draft Open Completed}.include?(state)
  end

  def success?
    response.success
  end

  def reason_code
    return nil if success_state?

    fetch("#{response_details}/#{@type}Status", "ReasonCode")
  end

  def response_code
    response.code
  end

  def error_code
    return nil if success?

    fetch("ErrorResponse/Error", "Code")
  end

  def error_message
    return nil if success?

    fetch("ErrorResponse/Error", "Message")
  end

  def error_response_present?
    !parse["ErrorResponse"].nil?
  end

  def body
    response.body
  end

  def parse
    Hash.from_xml(body)
  end

  class Authorization < SpreeAmazon::Response
    def response_details
      "AuthorizeResponse/AuthorizeResult/AuthorizationDetails"
    end

    def soft_decline?
      fetch(response_details, 'SoftDecline').to_s != 'false'
    end
  end

  class Capture < SpreeAmazon::Response
  end
  
  class SetOrderReferenceDetails < SpreeAmazon::Response
    
    def response_details
      "SetOrderReferenceDetailsResponse/SetOrderReferenceDetailsResult/OrderReferenceDetails"
    end
    
    def constraints
      fetch("#{response_details}/Constraints/Constraint" , 'Description')
    end
    
  end
end
