module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class AdyenGateway < Gateway

      # For live we use merchant-specific endpoints.
      # https://docs.adyen.com/developers/development-resources/live-endpoints
      self.test_url = 'https://checkout-test.adyen.com/checkout/v32/payments'
      self.supported_countries = ['AT', 'AU', 'BE', 'BG', 'BR', 'CH', 'CY', 'CZ', 'DE', 'DK', 'EE', 'ES', 'FI', 'FR', 'GB', 'GI', 'GR', 'HK', 'HU', 'IE', 'IS', 'IT', 'LI', 'LT', 'LU', 'LV', 'MC', 'MT', 'MX', 'NL', 'NO', 'PL', 'PT', 'RO', 'SE', 'SG', 'SK', 'SI', 'US']
      self.default_currency = 'USD'
      self.supported_cardtypes = [:visa, :master, :american_express, :diners_club, :jcb, :dankort, :maestro, :discover]
      self.money_format = :cents
      self.homepage_url = 'https://www.adyen.com/'
      self.display_name = 'Adyen'

      STANDARD_ERROR_CODE_MAPPING = {
          '101' => STANDARD_ERROR_CODE[:incorrect_number],
          '103' => STANDARD_ERROR_CODE[:invalid_cvc],
          '131' => STANDARD_ERROR_CODE[:incorrect_address],
          '132' => STANDARD_ERROR_CODE[:incorrect_address],
          '133' => STANDARD_ERROR_CODE[:incorrect_address],
          '134' => STANDARD_ERROR_CODE[:incorrect_address],
          '135' => STANDARD_ERROR_CODE[:incorrect_address],
      }

      def initialize(options = {})
        requires!(options, :api_key, :merchant_account)
        @api_key, @merchant_account = options.values_at(:api_key, :merchant_account)
        super
      end

      def purchase(money, payment, options = {})
        MultiResponse.run do |r|
          r.process {authorize(money, payment, options)}
          r.process {capture(money, r.authorization, options)}
        end
      end

      def authorize(money, payment, options = {})
        requires!(options, :order_id)
        post = init_post(options)
        add_invoice(post, money, options)
        add_payment(post, payment)
        add_extra_data(post, payment, options)
        add_shopper_interaction(post, payment, options)
        add_address(post, options)
        add_installments(post, options) if options[:installments]
        add_application_info(post)
        commit('payments', post)
      end

      def capture(money, authorization, options = {})
        post = init_post(options)
        add_invoice_for_modification(post, money, options)
        add_reference(post, authorization, options)
        add_application_info(post)
        commit('capture', post)
      end

      def refund(money, authorization, options = {})
        post = init_post(options)
        add_invoice_for_modification(post, money, options)
        add_original_reference(post, authorization, options)
        add_application_info(post)
        commit('refund', post)
      end

      def void(authorization, options = {})
        post = init_post(options)
        add_reference(post, authorization, options)
        add_application_info(post)
        commit('cancel', post)
      end

      def store(credit_card, options = {})
        requires!(options, :order_id)
        post = init_post(options)
        add_invoice(post, 0, options)
        add_payment(post, credit_card)
        add_extra_data(post, credit_card, options)
        add_recurring_contract(post)
        add_address(post, options)
        add_application_info(post)
        commit('authorise', post)
      end

      def verify(credit_card, options = {})
        MultiResponse.run(:use_first_response) do |r|
          r.process {authorize(0, credit_card, options)}
          r.process(:ignore_result) {void(r.authorization, options)}
        end
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
            gsub(%r((Authorization: Basic )\w+), '\1[FILTERED]').
            gsub(%r(("number\\?":\\?")[^"]*)i, '\1[FILTERED]').
            gsub(%r(("cvc\\?":\\?")[^"]*)i, '\1[FILTERED]').
            gsub(%r(("cavv\\?":\\?")[^"]*)i, '\1[FILTERED]')
      end

      private

      AVS_MAPPING = {
          '0' => 'R', # Unknown
          '1' => 'A', # Address matches, postal code doesn't
          '2' => 'N', # Neither postal code nor address match
          '3' => 'R', # AVS unavailable
          '4' => 'E', # AVS not supported for this card type
          '5' => 'U', # No AVS data provided
          '6' => 'Z', # Postal code matches, address doesn't match
          '7' => 'D', # Both postal code and address match
          '8' => 'U', # Address not checked, postal code unknown
          '9' => 'B', # Address matches, postal code unknown
          '10' => 'N', # Address doesn't match, postal code unknown
          '11' => 'U', # Postal code not checked, address unknown
          '12' => 'B', # Address matches, postal code not checked
          '13' => 'U', # Address doesn't match, postal code not checked
          '14' => 'P', # Postal code matches, address unknown
          '15' => 'P', # Postal code matches, address not checked
          '16' => 'N', # Postal code doesn't match, address unknown
          '17' => 'U', # Postal code doesn't match, address not checked
          '18' => 'I' # Neither postal code nor address were checked
      }

      CVC_MAPPING = {
          '0' => 'P', # Unknown
          '1' => 'M', # Matches
          '2' => 'N', # Does not match
          '3' => 'P', # Not checked
          '4' => 'S', # No CVC/CVV provided, but was required
          '5' => 'U', # Issuer not certifed by CVC/CVV
          '6' => 'P' # No CVC/CVV provided
      }

      NETWORK_TOKENIZATION_CARD_SOURCE = {
          'apple_pay' => 'applepay',
          'android_pay' => 'androidpay',
          'google_pay' => 'paywithgoogle'
      }

      def add_extra_data(post, payment, options)
        post[:shopperEmail] = options[:shopper_email] if options[:shopper_email]
        post[:shopperIP] = options[:shopper_ip] if options[:shopper_ip]
        post[:shopperReference] = options[:shopper_reference] if options[:shopper_reference]
        post[:fraudOffset] = options[:fraud_offset] if options[:fraud_offset]
        post[:selectedBrand] = options[:selected_brand] if options[:selected_brand]
        post[:selectedBrand] ||= NETWORK_TOKENIZATION_CARD_SOURCE[payment.source.to_s] if payment.is_a?(NetworkTokenizationCreditCard)
        post[:deliveryDate] = options[:delivery_date] if options[:delivery_date]
        post[:merchantOrderReference] = options[:merchant_order_reference] if options[:merchant_order_reference]
        post[:additionalData] ||= {}
        post[:additionalData][:overwriteBrand] = normalize(options[:overwrite_brand]) if options[:overwrite_brand]
        post[:additionalData][:customRoutingFlag] = options[:custom_routing_flag] if options[:custom_routing_flag]
        post[:additionalData]['paymentdatasource.type'] = NETWORK_TOKENIZATION_CARD_SOURCE[payment.source.to_s] if payment.is_a?(NetworkTokenizationCreditCard)
      end

      def add_shopper_interaction(post, payment, options = {})
        if (payment.respond_to?(:verification_value) && payment.verification_value) || payment.is_a?(NetworkTokenizationCreditCard)
          shopper_interaction = 'Ecommerce'
        else
          shopper_interaction = 'ContAuth'
        end

        post[:shopperInteraction] = options[:shopper_interaction] || shopper_interaction
      end

      def add_address(post, options)
        if (address = options[:billing_address] || options[:address]) && address[:country]
          post[:billingAddress] = {}
          post[:billingAddress][:street] = address[:address1] || 'N/A'
          post[:billingAddress][:houseNumberOrName] = address[:address2] || 'N/A'
          post[:billingAddress][:postalCode] = address[:zip] if address[:zip]
          post[:billingAddress][:city] = address[:city] || 'N/A'
          post[:billingAddress][:stateOrProvince] = address[:state] if address[:state]
          post[:billingAddress][:country] = address[:country] if address[:country]
        end
      end

      def add_invoice(post, money, options)
        amount = {
            value: amount(money),
            currency: options[:currency] || currency(money)
        }
        post[:amount] = amount
        post[:recurringProcessingModel] = options[:recurring_processing_model] if options[:recurring_processing_model]
      end

      def add_invoice_for_modification(post, money, options)
        amount = {
            value: amount(money),
            currency: options[:currency] || currency(money)
        }
        post[:modificationAmount] = amount
      end

      def add_payment(post, payment)
        if payment.is_a?(String)
          _, _, recurring_detail_reference = payment.split('#')
          post[:selectedRecurringDetailReference] = recurring_detail_reference
          add_recurring_contract(post)
        else
          add_mpi_data_for_network_tokenization_card(post, payment) if payment.is_a?(NetworkTokenizationCreditCard)
          add_card(post, payment)
        end
      end

      def add_card(post, credit_card)
        card = {
            type: 'scheme',
            expiryMonth: credit_card.month,
            expiryYear: credit_card.year,
            holderName: credit_card.name,
            number: credit_card.number,
            cvc: credit_card.verification_value
        }

        card.delete_if {|k, v| v.blank?}
        card[:holderName] ||= 'Not Provided' if credit_card.is_a?(NetworkTokenizationCreditCard)
        requires!(card, :type, :expiryMonth, :expiryYear, :holderName, :number)
        post[:paymentMethod] = card
      end

      def add_reference(post, authorization, options = {})
        _, psp_reference, _ = authorization.split('#')
        post[:originalReference] = single_reference(authorization) || psp_reference
      end

      def add_original_reference(post, authorization, options = {})
        original_psp_reference, _, _ = authorization.split('#')
        post[:originalReference] = single_reference(authorization) || original_psp_reference
      end

      def add_mpi_data_for_network_tokenization_card(post, payment)
        post[:mpiData] = {}
        post[:mpiData][:authenticationResponse] = 'Y'
        post[:mpiData][:cavv] = payment.payment_cryptogram
        post[:mpiData][:directoryResponse] = 'Y'
        post[:mpiData][:eci] = payment.eci || '07'
      end

      def single_reference(authorization)
        authorization if !authorization.include?('#')
      end

      def add_recurring_contract(post)
        post[:enableRecurring] = true
      end

      def add_installments(post, options)
        post[:installments] = {
            value: options[:installments]
        }
      end

      def add_application_info(post)

        externalPlatform = {
            "externalPlatform": {
                name: 'Shopify',
                version: "#{ActiveMerchant::VERSION}"
            },
            "adyenPaymentSource": {
                "name": "adyen-shopify",
                "version": "#{ActiveMerchant::VERSION}"
            }
        }

        post[:applicationInfo] = externalPlatform
      end

      def parse(body)
        return {} if body.blank?
        JSON.parse(body)
      end

      def commit(action, parameters)
        begin
          raw_response = ssl_post("#{url(action)}", post_data(parameters), request_headers)
          response = parse(raw_response)
        rescue ResponseError => e
          raw_response = e.response.body
          response = parse(raw_response)
        end
        success = success_from(action, response)
        Response.new(
            success,
            message_from(action, response),
            response,
            authorization: authorization_from(action, parameters, response),
            test: test?,
            error_code: success ? nil : error_code_from(response),
            avs_result: AVSResult.new(:code => avs_code_from(response)),
            cvv_result: CVVResult.new(cvv_result_from(response))
        )
      end

      def avs_code_from(response)
        AVS_MAPPING[response['additionalData']['avsResult'][0..1].strip] if response.dig('additionalData', 'avsResult')
      end

      def cvv_result_from(response)
        CVC_MAPPING[response['additionalData']['cvcResult'][0]] if response.dig('additionalData', 'cvcResult')
      end

      def url(action)
        if (action == 'payments')
          if test?
            "https://checkout-test.adyen.com/checkout/v32/#{action}"
          else
            "https://#{@options[:live_endpoint_url_prefix]}-checkout-live.adyenpayments.com/checkout/v32/#{action}"
          end
        else
          if test?
            "https://pal-test.adyen.com/pal/servlet/Payment/#{action}"
          else
            "https://#{@options[:live_endpoint_url_prefix]}-pal-live.adyenpayments.com/pal/servlet/Payment/#{action}"
          end
        end
      end


      def request_headers
        {
            'Content-Type' => 'application/json',
            'x-api-key' => "#{@api_key}"
        }
      end

      def success_from(action, response)
        case action.to_s
        when 'payments'
          ['Authorised', 'Received', 'RedirectShopper'].include?(response['resultCode'])
        when 'capture', 'refund', 'cancel'
          response['response'] == "[#{action}-received]"
        else
          false
        end
      end

      def message_from(action, response)
        return authorize_message_from(response) if action.to_s == 'authorise'
        response['response'] || response['message']
      end

      def authorize_message_from(response)
        if response['refusalReason'] && response['additionalData'] && response['additionalData']['refusalReasonRaw']
          "#{response['refusalReason']} | #{response['additionalData']['refusalReasonRaw']}"
        else
          response['refusalReason'] || response['resultCode'] || response['message']
        end
      end

      def authorization_from(action, parameters, response)
        return nil if response['pspReference'].nil?
        recurring = response['additionalData']['recurring.recurringDetailReference'] if response['additionalData']
        "#{parameters[:originalReference]}##{response['pspReference']}##{recurring}"
      end

      def init_post(options = {})
        post = {}
        post[:merchantAccount] = options[:merchant_account] || @merchant_account
        post[:reference] = options[:order_id] if options[:order_id]
        post
      end

      def post_data(parameters = {})
        JSON.generate(parameters)
      end

      def error_code_from(response)
        STANDARD_ERROR_CODE_MAPPING[response['errorCode']]
      end
    end
  end
end
