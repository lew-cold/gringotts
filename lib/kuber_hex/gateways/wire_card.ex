# call => Kuber.Hex.Gateways.WireCard.authorize(100, creditcard, options)
import XmlBuilder
defmodule Kuber.Hex.Gateways.WireCard do
  @test_url "https://c3-test.wirecard.com/secure/ssl-gateway"
  @live_url "https://c3.wirecard.com/secure/ssl-gateway"
  @homepage_url "http://www.wirecard.com"
  @envelope_namespaces %{
    "xmlns:xsi" => "http://www.w3.org/1999/XMLSchema-instance",
    "xsi:noNamespaceSchemaLocation" => "wirecard.xsd"
  }

  @permited_transactions ~w[ PREAUTHORIZATION CAPTURE PURCHASE ]

  @return_codes ~w[ ACK NOK ]
  @doc """
    Wirecard only allows phone numbers with a format like this: +xxx(yyy)zzz-zzzz-ppp, where:
      xxx = Country code
      yyy = Area or city code
      zzz-zzzz = Local number
      ppp = PBX extension
    For example, a typical U.S. or Canadian number would be "+1(202)555-1234-739" indicating PBX extension 739 at phone
    number 5551234 within area code 202 (country code 1).
  """
  @valid_phone_format ~r/\+\d{1,3}(\(?\d{3}\)?)?\d{3}-\d{4}-\d{3}/

  @supported_cardtypes [ :visa, :master, :american_express, :diners_club, :jcb, :switch ]
  @supported_countries ~w(AD CY GI IM MT RO CH AT DK GR IT MC SM TR BE EE HU LV NL SK GB BG FI IS LI NO SI VA FR IL LT PL ES CZ DE IE LU PT SE)
  @display_name      "Wirecard"
  @default_currency  "EUR"
  @money_format      :cents

  use Kuber.Hex.Gateways.Base
  alias Kuber.Hex.{
    CreditCard,
    Address,
    Response
  }

  import Poison, only: [decode!: 1]

  @doc """
    Authorization - the second parameter may be a CreditCard or
    a String which represents a GuWID reference to an earlier
    transaction.  If a GuWID is given, rather than a CreditCard,
    then then the :recurring option will be forced to "Repeated"
    ===========================================================
    TODO: Mandatorily check for :login,:password, :signature in options
    Note: payment_menthod for now is only credit_card and 
    TODO: change it so it can also have GuWID
    ================================================
    E.g: => 
    creditcard = %CreditCard{
      number: "4200000000000000",
      month: 12,
      year: 2018,
      first_name: "Longbob",
      last_name: "Longsen",
      verification_value: "123",
      brand: "visa"
    }
    address = %{
      name:     "Jim Smith",
      address1: "456 My Street",
      address2: "Apt 1",
      company:  "Widgets Inc",
      city:     "Ottawa",
      state:    "ON",
      zip:      "K1C2N6",
      country:  "CA",
      phone:    "(555)555-5555",
      fax:      "(555)555-6666"
    }
    options = [
      config: %{
        login: "00000031629CA9FA", 
        password: "TestXAPTER",
        signature: "00000031629CAFD5",
      },   
      order_id: 1,
      billing_address: address,
      description: 'Wirecard remote test purchase',
      email: "soleone@example.com",
      ip: "127.0.0.1"
    ] 
  """
  def authorize(money, payment_method, options \\ []) do
    options = options 
                |> check_and_return_payment_method(payment_method)

    response = commit(:post, :preauthorization, money, options)
    response
  end

  def capture(authorization, money, options \\ []) do
    options = options |> Keyword.put(:preauthorization, authorization)
    commit(:post, :capture, money, options)
  end

  @doc """
    Purchase - the second parameter may be a CreditCard or
    a String which represents a GuWID reference to an earlier
    transaction.  If a GuWID is given, rather than a CreditCard,
    then then the :recurring option will be forced to "Repeated"
  """
  def purchase(money, payment_method, options \\ []) do
    options = options 
                |> check_and_return_payment_method(payment_method)
    commit(:post, :purchase, money, options)
  end
 
  def void(identification, options \\ []) do
    options = options 
                |> Keyword.put(:preauthorization, identification)
    commit(:post, :reversal, nil, options)
  end
 
  def refund(money, identification, options \\ []) do
    options = options
                |> Keyword.put(:preauthorization, identification)
    commit(:post, :bookback, money, options)
  end

  @doc """
    Store card - Wirecard supports the notion of "Recurring
    Transactions" by allowing the merchant to provide a reference
    to an earlier transaction (the GuWID) rather than a credit
    card.  A reusable reference (GuWID) can be obtained by sending
    a purchase or authorization transaction with the element
    "RECURRING_TRANSACTION/Type" set to "Initial".  Subsequent
    transactions can then use the GuWID in place of a credit
    card by setting "RECURRING_TRANSACTION/Type" to "Repeated".
    
    This implementation of card store utilizes a Wirecard
    "Authorization Check" (a Preauthorization that is automatically
    reversed).  It defaults to a check amount of "100" (i.e.
    $1.00) but this can be overriden (see below).
    
    IMPORTANT: In order to reuse the stored reference, the
    +authorization+ from the response should be saved by
    your application code.
    
    ==== Options specific to +store+
    
    * <tt>:amount</tt> -- The amount, in cents, that should be
      "validated" by the Authorization Check.  This amount will
      be reserved and then reversed.  Default is 100.
    
    Note: This is not the only way to achieve a card store
    operation at Wirecard.  Any +purchase+ or +authorize+
    can be sent with +options[:recurring] = 'Initial'+ to make
    the returned authorization/GuWID usable in later transactions
    with +options[:recurring] = 'Repeated'+.
  """
  def store(creditcard, options \\ []) do
    options = options 
                |> Keyword.put(:credit_card, creditcard) 
                |> Keyword.put(:recurring, "Initial")
    money = options[:amount] || 100
    # Amex does not support authorization_check
    case creditcard.brand do
      "american_express" -> commit(:post, :preauthorization, money, options)
      _                 ->  commit(:post, :authorization_check, money, options)
    end
  end
 
  # =================== Private Methods =================== 
  
  defp check_and_return_payment_method(options, payment_method) do
    case payment_method do
      %CreditCard{}  ->
        options = options |> Keyword.put(:credit_card, payment_method)
      _             -> 
      options = options |> Keyword.put(:preauthorization, payment_method)
    end
    options
  end

  # Contact WireCard, make the XML request, and parse the
  # reply into a Response object.
  defp commit(method, action, money, options) do
    #TODO: validate and setup address hash as per AM
    request = build_request(action, money, options)
    
    headers = %{ "Content-Type" => "text/xml",
    "Authorization" => encoded_credentials(options[:config][:login], options[:config][:password]) }
    method |> HTTPoison.request(@test_url , request, headers) |> respond
  end
  
  defp respond({:ok, %{status_code: 200, body: body}}) do
    response = parse(body)
    {:ok, response}
  end

  defp respond({:ok, %{body: body, status_code: status_code}}) do
    { :error, "Some Error Occurred" }
  end

  # Read the XML message from the gateway and check if it was successful,
  # and also extract required return values from the response.
  # For Error => 
  # {:GuWID=>"C663288151298675530735",
  #  :AuthorizationCode=>"",
  #  :StatusType=>"INFO",
  #  :FunctionResult=>"NOK",
  #  :ERROR_Type=>"DATA_ERROR",
  #  :ERROR_Number=>"20080",
  #  :ERROR_Message=>"Could not find referenced transaction for GuWID C428094138244444404448.",
  #  :TimeStamp=>"2017-12-11 11:05:55",
  #  "ErrorCode"=>"20080",
  #  :Message=>"Could not find referenced transaction for GuWID C428094138244444404448."}
  # =================================================
  # For Response
  # TODO: parse XML Response
  defp parse(data) do    
    data 
      |> XmlToMap.naive_map
  end

  # Generates the complete xml-message, that gets sent to the gateway
  defp build_request(action, money, options) do
    options = options |> Keyword.put(:action, action)

    request = doc(element(:WIRECARD_BXML, [
        element(:W_REQUEST, [
          element(:W_JOB, [
            element(:JobID, ''),
            element(:BusinessCaseSignature, options[:config][:signature]),
            add_transaction_data(action, money, options)
          ])
        ])
      ]))

    request
  end

  
  # Includes the whole transaction data (payment, creditcard, address)
  # TODO: Add order_id to options if not present, see AM
  # TOOD: Clean description before passing it to FunctionID, replace dummy
  defp add_transaction_data(action, money, options) do
    element("FNC_CC_#{options[:action] |> atom_to_upcase_string}", [
      element(:FunctionID, "dummy_description"),
      element(:CC_TRANSACTION, [
        element(:TransactionID, options[:order_id]),
        element(:CommerceType, (if options[:commerce_type], do: options[:commerce_type]))      
      ] ++ add_action_data(action, money, options) ++ add_customer_data(options)
      )])
  end


  # Includes the IP address of the customer to the transaction-xml
  defp add_customer_data(options) do
    if options[:ip] do
      [
        element(:CONTACT_DATA, [ element(:IPAddress, options[:ip]) ])
      ]
    end
  end

  def add_action_data(action, money, options) do
    case options[:action] do
      # returns array of elements
      action when(action in [:preauthorization, :purchase, :authorization_check]) -> create_elems_for_preauth_or_purchase_or_auth_check(money, options)
      action when(action in [:capture, :bookback]) -> create_elems_for_capture_or_bookback(money, options)
      action when(action in [:reversal, :bookback]) -> add_guwid(options[:preauthorization])
    end
  end

  # Creates xml request elements if action is capture, bookback
  defp create_elems_for_capture_or_bookback(money, options) do
    add_guwid(options[:preauthorization]) ++ [add_amount(money, options)]
  end

  # Creates xml request elements if action is preauth, purchase ir auth_check 
  # TODO: handle nil values if array not generated
  defp create_elems_for_preauth_or_purchase_or_auth_check(money, options) do
    # TODO: setup_recurring_flag
    add_invoice(money, options) ++ element_for_credit_card_or_guwid(options) ++ add_address(options[:billing_address])
  end
  
  defp add_address(address) do
    if address do
      [
        element(:CORPTRUSTCENTER_DATA, [
          element(:ADDRESS, [
            element(:Address1, address[:address1]),
            element(:Address2, (if address[:address2], do: address[:address2])),
            element(:City, address[:city]),
            element(:Zip, address[:zip]), 
            add_state(address),
            element(:Country,address[:country]),
            element(:Phone, (if regex_match(@valid_phone_format ,address[:phone]), do: address[:phone])),
            element(:Email, address[:email])
          ])
        ])
      ]
    end
  end

  defp add_state(address) do
    if ( regex_match(~r/[A-Za-z]{2}/, address[:state]) && regex_match(~r/^(us|ca)$/i, address[:country]) 
    ) do
     element(:State, (String.upcase(address[:state])))
    end
  end

  defp element_for_credit_card_or_guwid(options) do
    if options[:credit_card] do
      add_creditcard(options[:credit_card])
    else
      add_guwid(options[:preauthorization])
    end
  end
  
  # Includes Guwid data to transaction-xml
  defp add_guwid(preauth) do
    [element(:GuWID, preauth)]
  end

  # Includes the credit-card data to the transaction-xml
  # TODO: Format Credit Card month, ref AM
  defp add_creditcard(creditcard) do
    [element(:CREDIT_CARD_DATA, [
      element(:CreditCardNumber, creditcard.number),
      element(:CVC2, creditcard.verification_value),
      element(:ExpirationYear, creditcard.year),
      element(:ExpirationMonth, creditcard.month),
      element(:CardHolderName, join_string([creditcard.first_name, creditcard.last_name], " "))
    ])]
  end


  # Includes the payment (amount, currency, country) to the transaction-xml
  def add_invoice(money, options) do
    [
      add_amount(money, options),
      element(:Currency, options[:currency] || @default_currency),
      element(:CountryCode, options[:billing_address][:country]),
      element(:RECURRING_TRANSACTION, [
        element(:Type, (options[:recurring] || "Single"))
      ])
    ]
  end
  
  # Include the amount in the transaction-xml
  # TODO: check for localized currency or currency
  # localized_amount(money, options[:currency] || currency(money))
  defp add_amount(money, options) do
    element(:Amount, money)
  end

  defp atom_to_upcase_string(atom) do
    String.upcase to_string atom
  end

  # Encode login and password in Base64 to supply as HTTP header
  # (for http basic authentication)
  defp encoded_credentials(login, password) do
    join_string([login, password], ":")
    |> Base.encode64 
    |> (&( "Basic "<> &1)).()
  end

  defp join_string(list_of_words, joiner) do
    Enum.join(list_of_words, joiner)
  end

  defp regex_match(regex, string) do
    Regex.match?(regex, string)
  end
end
