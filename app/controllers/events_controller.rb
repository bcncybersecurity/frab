class EventsController < BaseConferenceController
  include Searchable

  # GET /events
  # GET /events.json
  def index
    authorize @conference, :read?
    @events = search @conference.events.includes(:track)

    clean_events_attributes
    respond_to do |format|
      format.html { @events = @events.paginate page: page_param }
      format.json
    end
  end

  def export_accepted
    authorize @conference, :read?
    @events = @conference.events.is_public.accepted

    respond_to do |format|
      format.json { render :export }
    end
  end

  def export_confirmed
    authorize @conference, :read?
    @events = @conference.events.is_public.confirmed

    respond_to do |format|
      format.json { render :export }
    end
  end

  def export_all
    authorize @conference, :manage?
    @events = @conference.events.all

    respond_to do |format|
      format.json { render :export }
    end
  end

  # current_users events
  def my
    authorize @conference, :read?

    result = search @conference.events.associated_with(current_user.person)
    clean_events_attributes
    @events = result.paginate page: page_param
  end

  # events as pdf
  def cards
    authorize @conference, :manage?
    @events = if params[:accepted]
                @conference.events.accepted
              else
                @conference.events
              end

    respond_to do |format|
      format.pdf
    end
  end
  
  # show a table of all events' attachments
  def attachments
    authorize @conference, :read?
    
    result = search @conference.events
    @events = result.paginate page: page_param
    clean_events_attributes
    
    attachments = EventAttachment.joins(:event).where('events.conference': @conference)
    preset_attachment_titles_in_use = attachments.where(title: EventAttachment::ATTACHMENT_TITLES).group(:title).pluck(:title)
    
    @attachment_titles = EventAttachment::ATTACHMENT_TITLES & preset_attachment_titles_in_use
    
    @other_attachment_titles_exist = attachments.where.not(title: EventAttachment::ATTACHMENT_TITLES).any?
  end

  # show event ratings
  def ratings
    authorize @conference, :read?

    result = search @conference.events
    @events = result.paginate page: page_param
    clean_events_attributes

    # total ratings:
    @events_total = @conference.events.count
    @events_reviewed_total = @conference.events.to_a.count { |e| !e.event_ratings_count.nil? && e.event_ratings_count > 0 }
    @events_no_review_total = @events_total - @events_reviewed_total

    # current_user rated:
    @events_reviewed = @conference.events.joins(:event_ratings).where('event_ratings.person_id' => current_user.person.id).count
    @events_no_review = @events_total - @events_reviewed
  end

  # show event feedbacks
  def feedbacks
    authorize @conference, :read?
    result = search @conference.events.accepted
    @events = result.paginate page: page_param
  end

  # start batch event review
  def start_review
    authorize @conference, :read?
    ids = Event.ids_by_least_reviewed(@conference, current_user.person)
    if ids.empty?
      redirect_to action: 'ratings', notice: t('ratings_module.notice_already_rated_everything')
    else
      session[:review_ids] = ids
      redirect_to event_event_rating_path(event_id: ids.first)
    end
  end

  # GET /events/1
  # GET /events/1.json
  def show
    @event = authorize Event.find(params[:id])

    clean_events_attributes
    respond_to do |format|
      format.html # show.html.erb
      format.json
    end
  end

  # people tab of event detail page, the rating and
  # feedback tabs are handled in routes.rb
  # GET /events/2/people
  def people
    @event = authorize Event.find(params[:id])
  end

  # GET /events/new
  def new
    authorize @conference, :manage?
    @event = Event.new
    @start_time_options = @conference.start_times_by_day

    respond_to do |format|
      format.html # new.html.erb
    end
  end

  # GET /events/1/edit
  def edit
    @event = authorize Event.find(params[:id])
    @start_time_options = PossibleStartTimes.new(@event).all
  end

  # GET /events/2/edit_people
  def edit_people
    @event = authorize Event.find(params[:id])
    @persons = Person.fullname_options
  end

  # POST /events
  def create
    @event = Event.new(event_params)
    @event.conference = @conference
    authorize @event

    respond_to do |format|
      if @event.save
        format.html { redirect_to(@event, notice: t('cfp.event_created_notice')) }
      else
        @start_time_options = @conference.start_times_by_day
        format.html { render action: 'new' }
      end
    end
  end

  # PUT /events/1
  def update
    @event = authorize Event.find(params[:id])

    respond_to do |format|
      if @event.update_attributes(event_params)
        format.html { redirect_to(@event, notice: t('cfp.event_updated_notice')) }
        format.js   { head :ok }
      else
        flash_model_errors(@event)
        @start_time_options = PossibleStartTimes.new(@event).all
        format.html { render action: 'edit' }
        format.js { render json: @event.errors, status: :unprocessable_entity }
      end
    end
  end

  # update event state
  # GET /events/2/update_state?transition=cancel
  def update_state
    @event = authorize Event.find(params[:id])

    if params[:send_mail]

      # If integrated mailing is used, take care that a notification text is present.
      if @event.conference.notifications.empty?
        return redirect_to edit_conference_path, alert: t('emails_module.error_missing_notification_text')
      end

      return redirect_to(@event, alert: t('emails_module.error_missing_conference_email')) unless @conference.email

      return redirect_to(@event, alert: t('emails_module.error_missing_speaker_email')) unless @event.speakers.all?(&:email)
    end

    return redirect_to(@event, alert: t('emails_module.error_state_update')) unless @event.transition_possible?(params[:transition])

    begin
      @event.send(:"#{params[:transition]}!", send_mail: params[:send_mail], coordinator: current_user.person)
    rescue => ex
      return redirect_to(@event, alert: t('emails_module.error_state_update_ex', {ex: ex}))
    end

    redirect_to @event, notice: t('emails_module.notice_event_updated')
  end

  # add custom notifications to all the event's speakers
  # POST /events/2/custom_notification
  def custom_notification
    @event = authorize Event.find(params[:id])

    case @event.state
    when 'accepting'
      state = 'accept'
    when 'rejecting'
      state = 'reject'
    when 'confirmed'
      state = 'schedule'
    else
      return redirect_to(@event, alert: t('emails_module.error_unnotifiable_state'))
    end

    begin
      @event.event_people.presenter.each { |p| p.set_default_notification(state) }
    rescue Errors::NotificationMissingException => ex
      return redirect_to(@event, alert: t('emails_module.error_failed_setting_notification', {ex: ex}))
    end

    redirect_to edit_people_event_path(@event)
  end

  # DELETE /events/1
  def destroy
    @event = authorize Event.find(params[:id])
    @event.destroy

    respond_to do |format|
      format.html { redirect_to(events_url) }
    end
  end

  private

  def clean_events_attributes
    return if policy(@conference).manage?
    @event&.clean_event_attributes!
    @events&.map(&:clean_event_attributes!)
  end

  # returns duplicates if ransack has to deal with the associated model
  def search(events)
    filter = events
    filter = filter.where(state: params[:event_state]) if params[:event_state].present?
    filter = filter.where(event_type: params[:event_type]) if params[:event_type].present?
    filter = filter.where(track: @conference.tracks.find_by(:name => params[:track_name])) if params[:track_name].present?
    @search = perform_search(filter, params, %i(title_cont description_cont abstract_cont track_name_cont event_type_is))
    if params.dig('q', 's')&.match('track_name')
      @search.result
    else
      @search.result(distinct: true)
    end
  end

  def event_params
    params.require(:event).permit(
      :id, :title, :subtitle, :event_type, :time_slots, :state, :start_time, :public, :language, :abstract, :description, :logo, :track_id, :room_id, :note, :submission_note, :do_not_record, :recording_license, :tech_rider,
      event_attachments_attributes: %i(id title attachment public _destroy),
      ticket_attributes: %i(id remote_ticket_id),
      links_attributes: %i(id title url _destroy),
      event_classifiers_attributes: %i(id classifier_id value _destroy),
      event_people_attributes: %i(id person_id event_role role_state notification_subject notification_body _destroy)
    )
  end
end
