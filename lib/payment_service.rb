module PaymentService
  def self.hold_payment(payment_params)
    create_payment_intent(payment_params.merge(capture: false))
  end

  def self.immediate_capture_payment(payment_params)
    create_payment_intent(payment_params.merge(capture: true))
  end

  def self.capture_authorized_charge(charge_id)
    # @TODO: we can remove this code after 7 days of moving to payment intents
    charge = Stripe::Charge.retrieve(charge_id)
    charge.capture
    Transaction.new(external_id: charge.id, source_id: charge.payment_method, destination_id: charge.destination, amount_cents: charge.amount, transaction_type: Transaction::CAPTURE, status: Transaction::SUCCESS)
  rescue Stripe::StripeError => e
    generate_transaction_from_exception(e, Transaction::CAPTURE, external_id: charge_id)
  end

  def self.capture_authorized_payment(payment_intent_id)
    payment_intent = Stripe::PaymentIntent.retrieve(payment_intent_id)
    raise Errors::ProcessingError, :cannot_capture unless payment_intent.status == 'requires_capture'

    payment_intent.capture
    new_transaction = Transaction.new(external_id: payment_intent.id, source_id: payment_intent.payment_method, destination_id: payment_intent.transfer_data&.destination, amount_cents: payment_intent.amount, transaction_type: Transaction::CAPTURE)
    update_transaction_with_payment_intent(new_transaction, payment_intent)
    new_transaction
  end

  def refund_charge(charge_id)
    refund = Stripe::Refund.create(charge: charge_id, reverse_transfer: true)
    Transaction.new(external_id: refund.id, transaction_type: Transaction::REFUND, status: Transaction::SUCCESS)
  rescue Stripe::StripeError => e
    generate_transaction_from_exception(e, Transaction::REFUND, external_id: charge_id)
  end

  def self.refund_payment(external_id)
    payment_intent = Stripe::PaymentIntent.retrieve(external_id)
    refund = Stripe::Refund.create(charge: payment_intent.charges.first.id, reverse_transfer: true)
    Transaction.new(external_id: refund.id, transaction_type: Transaction::REFUND, status: Transaction::SUCCESS, external_type: Transaction::REFUND)
  rescue Stripe::StripeError => e
    generate_transaction_from_exception(e, Transaction::REFUND, external_id: external_id)
  end

  def self.create_payment_intent(credit_card:, buyer_amount:, seller_amount:, merchant_account:, currency_code:, description:, metadata: {}, capture:)
    payment_intent = Stripe::PaymentIntent.create(
      amount: buyer_amount,
      currency: currency_code,
      description: description,
      payment_method_types: ['card'],
      payment_method: credit_card[:external_id],
      customer: credit_card[:customer_account][:external_id],
      on_behalf_of: merchant_account[:external_id],
      transfer_data: {
        destination: merchant_account[:external_id],
        amount: seller_amount
      },
      metadata: metadata,
      capture_method: capture ? 'automatic' : 'manual',
      confirm: true, # it creates payment intent and tries to confirm at the same time
      setup_future_usage: 'off_session',
      confirmation_method: 'manual' # if requires action, we will confirm manually after
    )
    new_transaction = Transaction.new(
      external_id: payment_intent.id,
      source_id: payment_intent.payment_method,
      destination_id: merchant_account[:external_id],
      amount_cents: payment_intent.amount,
      external_type: Transaction::PAYMENT_INTENT,
      transaction_type: capture ? Transaction::CAPTURE : Transaction::HOLD,
      payload: payment_intent.to_h
    )
    update_transaction_with_payment_intent(new_transaction, payment_intent)
    new_transaction
  end

  def self.update_transaction_with_payment_intent(transaction, payment_intent)
    case payment_intent.status # https://stripe.com/docs/payments/intents#intent-statuses
    when 'requires_capture'
      transaction.status = Transaction::REQUIRES_CAPTURE
    when 'succeeded'
      transaction.status = Transaction::SUCCESS
    when 'requires_payment_method'
      # attempting confirm failed
      transaction.status = Transaction::FAILURE
      transaction.failure_code = payment_intent.last_payment_error.code
      transaction.failure_message = payment_intent.last_payment_error.message
      transaction.decline_code = payment_intent.last_payment_error.decline_code
    else
      # unknown status raise error
      raise "Unsupported payment_intent status: #{payment_intent.status}"
    end
  end

  def self.generate_transaction_from_exception(exc, type, external_id: nil)
    body = exc.json_body[:error]
    Transaction.new(
      external_id: external_id || body[:charge],
      failure_code: body[:code],
      failure_message: body[:message],
      decline_code: body[:decline_code],
      transaction_type: type,
      status: Transaction::FAILURE,
      payload: exc.json_body
    )
  end
end
