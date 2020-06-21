require 'net/http'
require 'securerandom'
require 'openssl'
require 'time'
require 'active_support/core_ext'

require 'amazon/charge_permission'
require 'amazon/charge'
require 'amazon/checkout_session'
require 'amazon/refund'
require 'amazon/response'
require 'amazon/delivery_trackers'

module AmazonPay
  @@amazon_signature_algorithm = 'AMZN-PAY-RSASSA-PSS'.freeze
  @@hash_algorithm = 'SHA256'.freeze
  @@public_key_id = nil
  @@region = nil
  @@sandbox = 'true'
  @@private_key = 'private.pem'

  def self.region=(region)
    @@region = region
  end

  def self.public_key_id=(public_key_id)
    @@public_key_id = public_key_id
  end

  def self.sandbox=(sandbox)
    @@sandbox = sandbox
  end

  def self.private_key=(private_key)
    @@private_key = private_key
  end

  def self.request(method_type, url, body = nil)
    method_types = {
      'post' => Net::HTTP::Post,
      'get' => Net::HTTP::Get,
      'put' => Net::HTTP::Put,
      'patch' => Net::HTTP::Patch,
      'delete' => Net::HTTP::Delete
    }

    url = base_api_url + url

    uri = URI.parse(url)
    request = method_types[method_type.downcase].new(uri)
    request['content-type'] = 'application/json'
    if method_type.downcase == 'post'
      request['x-amz-pay-idempotency-key'] = SecureRandom.hex(10)
    end
    request['x-amz-pay-date'] = formatted_timestamp

    request_payload = JSON.dump(body) if body.present?
    request.body = request_payload

    headers = request
    request_parameters = {}
    signed_headers = signed_headers(method_type.downcase, url, request_parameters, request_payload, headers)
    signed_headers.each { |key, value| request[key] = value }

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(request)
    end

    AmazonPay::Response.new response
  end

  def self.signed_headers(http_request_method, request_uri, request_parameters, request_payload, other_presigned_headers = nil)
    request_payload ||= ''
    request_payload = check_for_payment_critical_data_api(request_uri, http_request_method, request_payload)
    pre_signed_headers = {}
    pre_signed_headers['accept'] = 'application/json'
    pre_signed_headers['content-type'] = 'application/json'
    pre_signed_headers['x-amz-pay-region'] = @@region

    if other_presigned_headers.present?
      other_presigned_headers.each do |key, val|
        next unless key.downcase == 'x-amz-pay-idempotency-key' && val.present?
        pre_signed_headers['x-amz-pay-idempotency-key'] = val
      end
    end

    time_stamp = formatted_timestamp
    signature = create_signature(http_request_method, request_uri,
                                 request_parameters, pre_signed_headers,
                                 request_payload, time_stamp)
    headers = canonical_headers(pre_signed_headers)
    headers['x-amz-pay-date'] = time_stamp
    headers['x-amz-pay-host'] = amz_pay_host(request_uri)
    signed_headers = "SignedHeaders=#{canonical_headers_names(headers)}, Signature=#{signature}"
    # Do not add x-amz-pay-idempotency-key header here, as user-supplied headers get added later
    header_array = {}
    header_array['accept'] = string_from_array(headers['accept'])
    header_array['content-type'] = string_from_array(headers['content-type'])
    header_array['x-amz-pay-host'] = amz_pay_host(request_uri)
    header_array['x-amz-pay-date'] = time_stamp
    header_array['x-amz-pay-region'] = @@region
    header_array['authorization'] = "#{@@amazon_signature_algorithm} PublicKeyId=#{@@public_key_id}, #{signed_headers}"
    header_array.sort_by { |key, _value| key }.to_h
  end

  def self.create_signature(http_request_method, request_uri, request_parameters, pre_signed_headers, request_payload, time_stamp)
    rsa = OpenSSL::PKey::RSA.new(File.read(@@private_key))
    pre_signed_headers['x-amz-pay-date'] = time_stamp
    pre_signed_headers['x-amz-pay-host'] = amz_pay_host(request_uri)
    hashed_payload = hex_and_hash(request_payload)
    canonical_uri = canonical_uri(request_uri)
    canonical_query_string = create_canonical_query(request_parameters)
    canonical_header = header_string(pre_signed_headers)
    signed_headers = canonical_headers_names(pre_signed_headers)
    canonical_request = "#{http_request_method.upcase}\n#{canonical_uri}\n#{canonical_query_string}\n#{canonical_header}\n#{signed_headers}\n#{hashed_payload}"
    hashed_canonical_request = "#{@@amazon_signature_algorithm}\n#{hex_and_hash(canonical_request)}"
    Base64.strict_encode64(rsa.sign_pss(@@hash_algorithm, hashed_canonical_request, salt_length: 20, mgf1_hash: @@hash_algorithm))
  end

  def self.hex_and_hash(data)
    Digest::SHA256.hexdigest(data)
  end

  def self.check_for_payment_critical_data_api(request_uri, http_request_method, request_payload)
    payment_critical_data_apis = ['/live/account-management/v1/accounts', '/sandbox/account-management/v1/accounts']
    allowed_http_methods = %w[post put patch]
    # For APIs handling payment critical data, the payload shouldn't be
    # considered in the signature calculation
    payment_critical_data_apis.each do |api|
      if request_uri.include?(api) && allowed_http_methods.include?(http_request_method.downcase)
        return ''
      end
    end
    request_payload
  end

  def self.formatted_timestamp
    Time.now.utc.iso8601.split(/[-,:]/).join
  end

  def self.canonical_headers(headers)
    sorted_canonical_array = {}
    headers.each do |key, val|
      sorted_canonical_array[key.to_s.downcase] = val if val.present?
    end
    sorted_canonical_array.sort_by { |key, _value| key }.to_h
  end

  def self.amz_pay_host(url)
    return '/' unless url.present?
    parsed_url = URI.parse(url)

    if parsed_url.host.present?
      parsed_url.host
    else
      '/'
    end
  end

  def self.canonical_headers_names(headers)
    sorted_header = canonical_headers(headers)
    parameters = []
    sorted_header.each { |key, _value| parameters << key }
    parameters.sort!
    parameters.join(';')
  end

  def self.string_from_array(array_data)
    if array_data.is_a?(Array)
      collect_sub_val(array_data)
    else
      array_data
    end
  end

  def self.collect_sub_val(parameters)
    category_index = 0
    collected_values = ''

    parameters.each do |value|
      collected_values += ' ' unless category_index.zero?
      collected_values += value
      category_index += 1
    end
    collected_values
  end

  def self.canonical_uri(unencoded_uri)
    return '/' if unencoded_uri == ''

    url_array = URI.parse(unencoded_uri)
    if url_array.path.present?
      url_array.path
    else
      '/'
    end
  end

  def self.create_canonical_query(request_parameters)
    sorted_request_parameters = sort_canonical_array(request_parameters)
    parameters_as_string(sorted_request_parameters)
  end

  def self.sort_canonical_array(canonical_array)
    sorted_canonical_array = {}
    canonical_array.each do |key, val|
      if val.is_a?(Object)
        sub_arrays(val, key.to_s).each do |new_key, sub_val|
          sorted_canonical_array[new_key.to_s] = sub_val
        end
      elsif !val.present
      else
        sorted_canonical_array[key.to_s] = val
      end
    end
    sorted_canonical_array.sort_by { |key, _value| key }.to_h
  end

  def self.sub_arrays(parameters, category)
    category_index = 0
    new_parameters = {}
    category_string = "#{category}."
    parameters.each do |value|
      category_index += 1
      new_parameters["#{category_string}#{category_index}"] = value
    end
    new_parameters
  end

  def self.parameters_as_string(parameters)
    query_parameters = []
    parameters.each do |key, value|
      query_parameters << "#{key}=#{url_encode(value)}"
    end
    query_parameters.join('&')
  end

  def self.url_encode(value)
    URI::encode(value).gsub('%7E', '~')
  end

  def self.header_string(headers)
    query_parameters = []
    sorted_headers = canonical_headers(headers)

    sorted_headers.each do |key, value|
      if value.is_a?(Array)
        value = collect_sub_val(value)
      else
        query_parameters << "#{key}:#{value}"
      end
    end
    return_string = query_parameters.join("\n")
    "#{return_string}\n"
  end

  def self.base_api_url
    sandbox = @@sandbox ? 'sandbox' : 'live'
    {
      'us' => "https://pay-api.amazon.com/#{sandbox}/v1/",
      'uk' => "https://pay-api.amazon.eu/#{sandbox}/v1/",
      'de' => "https://pay-api.amazon.eu/#{sandbox}/v1/",
      'jp' => "https://pay-api.amazon.jp/#{sandbox}/v1/",
    }.fetch(@@region)
  end
end
