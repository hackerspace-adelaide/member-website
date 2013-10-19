class MembershipsController < ApplicationController
  before_action :set_membership, only: [:show, :edit, :update, :destroy]

  def express

    # authorize! :update, Membership
    
    @autodebit = false
    @concession = false

    if params[:one_year_recurring]
      @autodebit = true
      @express_purchase_membership_duration = 12
    elsif params[:six_month_recurring]
      @autodebit = true
      @express_purchase_membership_duration = 6
    end

    if params[:one_year]
      @express_purchase_membership_duration = 12
    elsif params[:six_month]
      @express_purchase_membership_duration = 6
    end

    if params[:concession] == "1"
      @concession = true
      logger.info 'Concession selected.'
    end

    params[:duration] = @express_purchase_membership_duration
    @express_purchase_price = Membership.calculate_membership_price(@express_purchase_membership_duration, {autodebit: @autodebit, concession: @concession})
    session[:express_autodebit] = @autodebit
    session[:express_concession] = @concession
    session[:express_purchase_price] = @express_purchase_price
    session[:express_purchase_membership_duration] = @express_purchase_membership_duration

    if @autodebit
      # Autodebit setup

      if @concession == true
          payment_description = "#{session[:express_purchase_membership_duration]} monthly automatic-debit for a Hackerspace Adelaide membership (concession)."
      else
          payment_description = "#{session[:express_purchase_membership_duration]} monthly automatic-debit for a Hackerspace Adelaide membership."
      end
      session[:express_purchase_description] = payment_description

      ppr = PayPal::Recurring.new({
        :return_url   => new_membership_url,
        :cancel_url   => new_membership_url,
        :description  => payment_description,
        :amount       => (session[:express_purchase_price] / 100),
        :currency     => 'AUD'
      })
      response = ppr.checkout
      redirect_to response.checkout_url if response.valid?
    else
      if @concession == true
        payment_description = "Hackerspace Adelaide membership (concession)."
      else
        payment_description = "Hackerspace Adelaide membership."
      end
      session[:express_purchase_description] = payment_description

      response = EXPRESS_GATEWAY.setup_purchase(@express_purchase_price,
        :ip                 => request.remote_ip,
        :return_url         => new_membership_url,
        :cancel_return_url  => new_membership_url,
        :allow_note         => true,
        :items              => [{:name => "#{session[:express_purchase_membership_duration]} month Hackerspace Adelaide membership.", :quantity => 1, :description => payment_description, :amount => session[:express_purchase_price]}],
        :currency           => 'AUD'
      )
      logger.info "XXXXXXXXXXXX"
      logger.info @express_purchase_price
      logger.info response.to_json
      redirect_to EXPRESS_GATEWAY.redirect_url_for(response.token)
    end
  end

  # GET /memberships
  # GET /memberships.json
  def index
    @memberships = Membership.all
    @membership = Membership.new
  end

  # GET /memberships/1
  # GET /memberships/1.json
  def show
  end

  # GET /memberships/new
  def new

    @user = current_user

    if @user.is_admin?
      # Let admins create memberships manually
      @membership = Membership.new
    else
      # Pay via PayPal
      @membership = Membership.new
      @express_token = params[:token]
      @express_payer_id = params[:PayerID]

      @has_token = not(@express_token.blank? or @express_payer_id.blank?)

      if @has_token
          retrieve_paypal_express_details(@express_token, {autodebit: session[:express_autodebit]})
          session[:express_token] = @express_token
          session[:express_payer_id] = @express_payer_id
      else
          logger.info "*** No token. ***"
      end
    end
  end

  # GET /memberships/1/edit
  def edit
    @user = current_user
    @membership = Membership.find(params[:id])
    @cancel_membership = true
  end

  # POST /memberships
  # POST /memberships.json
  def create

    @user = current_user
    if @user.is_admin?
      # Make a new membership.
      @membership = Membership.new(membership_params)
      @membership.purchase_date = DateTime.now
    else
      # Do the PayPal purchase
      payment_complete = false
      notice_message_for_user = "Something went wrong, sorry!"
      @user = current_user
      @membership = @user.memberships.build(:valid_from => (@user.last_membership.try(:expiry_date) or DateTime.now), :duration => session[:express_purchase_membership_duration], :purchase_date => DateTime.now)

      if session[:express_autodebit]
          # It's an autodebit, so set that up
          # 1. setup autodebit by requesting payment
          ppr = PayPal::Recurring.new({
            :token       => session[:express_token],
            :payer_id    => session[:express_payer_id],
            :amount      => (session[:express_purchase_price] / 100),
            :ipn_url     => "#{payment_notifications_url}",
            :currency    => 'AUD',
            :description => session[:express_purchase_description]
          })
          response_request = ppr.request_payment

          if response_request.approved? and response_request.completed?
              # 2. create profile & save recurring profile token
              # Set :period to :daily and :frequency to 1 for testing IPN every minute
              ppr = PayPal::Recurring.new({
                :token       => session[:express_token],
                :payer_id    => session[:express_payer_id],
                :amount      => (session[:express_purchase_price] / 100),
                :currency    => 'AUD',
                :description => session[:express_purchase_description],
                :frequency   => session[:express_purchase_membership_duration], # 1,
                :period      => :monthly, # :daily,
                :reference   => "#{current_user.id}",
                :ipn_url     => "#{payment_notifications_url}",
                :start_at    => (@membership.valid_from + session[:express_purchase_membership_duration].months), # Time.now
                :failed      => 1,
                :outstanding => :next_billing
              })

              response_create = ppr.create_recurring_profile
              if not(response_create.profile_id.blank?)
                  @membership.paypal_profile_id = response_create.profile_id
                  # If successful, update the user's subscription date.
                  # update_membership_expiry_date
                  # Reset refund if they had one in the past
                  @membership.refund = nil

                  # TODO: Background task
                  # TODO: Check paypal recurring profile id still valid
                  # TODO: Setup future update_membership_expiry_date

                  # Save the PayPal data to the @membership model for receipts
                  save_paypal_data_to_membership_model
                  payment_complete = true
              else
                  # Why didn't this work? Log it.
                  logger.warn "create_recurring_profile failed: #{response_create.params}"
              end
          else
              # Why didn't this work? Log it.
              logger.warn "request_payment failed: #{response_request.params}"
              notice_message_for_user = response_request.params[:L_LONGMESSAGE0]
          end
      else
          # It's a single purchase so make the PayPal purchase
          response = EXPRESS_GATEWAY.purchase(session[:express_purchase_price], express_purchase_options)

          if response.success?
              # If successful, update the user's subscription date.
              # update_membership_expiry_date
              logger.info "Paypal is happy!"
              save_paypal_data_to_membership_model
              payment_complete = true
          else
              # The user probably hit back and refresh or paypal is broken.
              logger.info "Paypal is sad."
              logger.warn response.params
              notice_message_for_user = response.message
              # redirect_to user_path(current_user), notice: response.message
              # return
          end
      end

    end

    respond_to do |format|
      if payment_complete and @membership.save
        format.html { redirect_to user_path(@user), notice: 'Membership was successfully created.' }
        format.json { render action: 'show', status: :created, location: @membership }
      else
        logger.info "Uh oh, couldn't save......."
        # raise "couldn't save."
        format.html { render action: 'index', notice: @membership.errors }
        format.json { render json: @membership.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /memberships/1
  # PATCH/PUT /memberships/1.json
  def update

    # TODO: Handle users cancelling their membership

    respond_to do |format|
      if @membership.update(membership_params)
        format.html { redirect_to @membership, notice: 'Membership was successfully updated.' }
        format.json { head :no_content }
      else
        format.html { render action: 'edit' }
        format.json { render json: @membership.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /memberships/1
  # DELETE /memberships/1.json
  def destroy
    @membership.destroy
    respond_to do |format|
      format.html { redirect_to memberships_url }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_membership
      @membership = Membership.find(params[:id])
    end

    # Never trust parameters from the scary internet, only allow the white list through.
    def membership_params
      params.require(:membership).permit(:user_id, :valid_from, :duration, :purchase_date)
    end

    def cancel_recurring_subscription
      ppr = PayPal::Recurring.new(:profile_id => @membership.paypal_profile_id)
      response = ppr.cancel
      if response.success?
        # Don't nil out paypal recurring profile.
        # @membership.paypal_profile_id = nil
        session[:express_autodebit] = false
        return true
      else
        return false
      end
    end

    def save_paypal_data_to_membership_model
      @membership.paypal_payer_id = session[:express_payer_id]
      @membership.paypal_email = session[:express_email]
      @membership.paypal_first_name = session[:express_first_name]
      @membership.paypal_last_name = session[:express_last_name]
      @membership.price_paid = session[:express_purchase_price]
      # @membership.paypal_profile_id also saved for recurring payments earlier
      @membership.paypal_street1 = session[:express_street1]
      @membership.paypal_street2 = session[:express_street2]
      @membership.paypal_city_name = session[:express_city_name]
      @membership.paypal_state_or_province = session[:express_state_or_province]
      @membership.paypal_country_name = session[:express_country_name]
      @membership.paypal_country_code = session[:express_country_code]
      @membership.paypal_postal_code = session[:express_postal_code]
      @membership.concession = session[:express_concession]
    end

    def express_purchase_options
      {
        :ip         => request.remote_ip,
        :token      => session[:express_token],
        :payer_id   => session[:express_payer_id],
        :items      => [{:name => "#{session[:express_purchase_membership_duration]} month Hackerspace Adelaide membership.", :quantity => 1, :description => "Hackerspace Adelaide membership.", :amount => session[:express_purchase_price]}],
        :currency   => 'AUD'
      }
    end

end
