module OfferService
  def self.create_pending_offer(order, amount_cents:, from_id:, from_type:, creator_id:, responds_to: nil)
    raise Errors::ValidationError, :cannot_offer unless order.mode == Order::OFFER
    raise Errors::ValidationError, :invalid_amount_cents unless amount_cents.positive?

    offer_totals = OfferTotals.new(order, amount_cents)
    order.offers.create!(
      amount_cents: amount_cents,
      from_id: from_id,
      from_type: from_type,
      creator_id: creator_id,
      responds_to: responds_to,
      shipping_total_cents: offer_totals.shipping_total_cents,
      tax_total_cents: offer_totals.tax_total_cents,
      should_remit_sales_tax: offer_totals.should_remit_sales_tax
    )
  end

  def self.create_pending_counter_offer(responds_to, amount_cents:, from_id:, from_type:, creator_id:)
    raise Errors::ValidationError, :invalid_state unless responds_to.order.state == Order::SUBMITTED
    raise Errors::ValidationError, :not_last_offer unless responds_to.last_offer?

    create_pending_offer(responds_to.order, amount_cents: amount_cents, from_id: from_id, from_type: from_type, creator_id: creator_id, responds_to: responds_to)
  end

  def self.submit_pending_offer(offer)
    order = offer.order
    order_helper = OrderHelper.new(order)

    raise Errors::ValidationError, :invalid_offer if offer.submitted?
    raise Errors::ProcessingError, :insufficient_inventory unless order_helper.inventory?

    order = offer.order
    offer_order_totals = OfferOrderTotals.new(offer)
    order.with_lock do
      offer.update!(submitted_at: Time.now.utc)
      order.update!(
        last_offer: offer,
        shipping_total_cents: offer_order_totals.shipping_total_cents,
        tax_total_cents: offer_order_totals.tax_total_cents,
        commission_rate: offer_order_totals.commission_rate,
        items_total_cents: offer_order_totals.items_total_cents,
        buyer_total_cents: offer_order_totals.buyer_total_cents,
        commission_fee_cents: offer_order_totals.commission_fee_cents,
        transaction_fee_cents: offer_order_totals.transaction_fee_cents,
        seller_total_cents: offer_order_totals.seller_total_cents,
        state_expires_at: Offer::EXPIRATION.from_now # expand order expiration
      )
    end
    post_submit_offer(offer)
    offer
  end

  def self.submit_order_with_offer(offer, user_id)
    order = offer.order
    validate_order_submission!(order)

    order.submit! do
      submit_pending_offer(offer)
    end

    Exchange.dogstatsd.increment 'order.submit'
    PostOrderNotificationJob.perform_later(order.id, Order::SUBMITTED, user_id)
  end

  class << self
    private

    def post_submit_offer(offer)
      OrderFollowUpJob.set(wait_until: offer.order.state_expires_at).perform_later(offer.order.id, offer.order.state)
      PostOfferNotificationJob.perform_later(offer.id, OfferEvent::SUBMITTED, offer.creator_id)
      OfferRespondReminderJob.set(wait_until: offer.order.state_expires_at - Order::DEFAULT_EXPIRATION_REMINDER)
                             .perform_later(offer.order.id, offer.id)
      Exchange.dogstatsd.increment 'offer.submit'
    end

    def validate_order_submission!(order)
      order_helper = OrderHelper.new(order)
      raise Errors::ValidationError, :cant_submit unless order.mode == Order::OFFER
      raise Errors::ValidationError, :missing_required_info unless order.can_commit?

      unless order_helper.valid_artwork_version?
        Exchange.dogstatsd.increment 'submit.artwork_version_mismatch'
        raise Errors::ProcessingError, :artwork_version_mismatch
      end
      credit_card_error = order_helper.assert_credit_card
      raise Errors::ValidationError, credit_card_error if credit_card_error
    end
  end
end
