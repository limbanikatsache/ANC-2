class GenericProgramsController < ApplicationController
  before_filter :find_patient, :except => [:void, :states]
  
  def new
    session[:return_to] = nil
    session[:return_to] = params[:return_to] unless params[:return_to].blank?
    program_names = PatientProgram.find(:all,
                                    :joins => "INNER JOIN location l ON l.location_id = patient_program.location_id
                                               INNER JOIN program p ON p.program_id = patient_program.program_id",
                                    :select => "p.name program_name ,l.name location_name,patient_program.date_completed date_completed",
                                    :conditions =>["voided = 0 AND patient_id = ? AND date_completed IS NULL",params[:patient_id]]
                                    ).map{|pat_program|
                                      [pat_program.program_name,pat_program.location_name] if pat_program.date_completed.blank?
                                    }
    @enrolled_program_names = program_names.to_json                                
    @patient_program = PatientProgram.new
  end

  def create
    active_programs = PatientProgram.find(:all,:conditions =>["voided = 0 AND patient_id = ? AND location_id = ? AND program_id = ?",
                                    @patient.id,params[:location_id],params[:program_id]])
    invalid_date = false
    initial_date = params[:initial_date].to_date
    active_programs.map{ | program |
		if !(program.date_completed.blank? and program.date_enrolled.blank?)
			#raise "Initial date -> " + initial_date.to_s + " Date enrolled -> " + program.date_enrolled.to_date.to_s + " Date completed -> " + program.date_completed.to_date.to_s
      		invalid_date = (initial_date >= program.date_enrolled.to_date and initial_date < program.date_completed.to_date)
		end
    }

    if invalid_date
      error = "Already enrolled in that program around that time: #{initial_date}"
      redirect_to :controller => "patients" ,:action => "programs",
        :error => error,:patient_id => @patient.id  and return
    end
    
    @patient_program = @patient.patient_programs.build(
      :program_id => params[:program_id],
      :date_enrolled => params[:initial_date],
      :location_id => params[:location_id])      
    @patient_state = @patient_program.patient_states.build(
      :state => params[:initial_state],
      :start_date => params[:initial_date]) 
    if @patient_program.save && @patient_state.save
      redirect_to session[:return_to] and return unless session[:return_to].blank?
      redirect_to :controller => :patients, :action => :programs_dashboard, :patient_id => @patient.patient_id
    else 
      flash.now[:error] = @patient_program.errors.full_messages.join(". ")
      render :action => "new"
    end
  end

  def status
    @program = PatientProgram.find(params[:id])
    render :layout => false    
  end
  
  def void
    @program = PatientProgram.find(params[:id])
    @program.void
    head :ok
  end  
  
  def locations
    #@locations = Location.most_common_program_locations(params[:q] || '')
    if params[:transfer_type].blank? || params[:transfer_type].nil?
        @locations = most_common_locations(params[:q] || '')
    else
        search = params[:q] || ''
        location_tag_id = LocationTag.find_by_name("#{params[:transfer_type]}").id
        location_ids = LocationTagMap.find(:all,:conditions => ["location_tag_id = (?)",location_tag_id]).map{|e|e.location_id}
        @locations = Location.find(:all, :conditions=>["location.retired = 0 AND location_id IN (?) AND name LIKE ? AND name != ''", location_ids, "#{search}%"])
    end
    @names = @locations.map do | location | 
      next if generic_locations.include?(location.name)
      "<li value='#{location.location_id}'>#{location.name}</li>" 
    end
    render :text => @names.join('')
  end
  
  def workflows
    @workflows = ProgramWorkflow.all(:conditions => ['program_id = ?', params[:program]], :include => :concept)
    @names = @workflows.map{|workflow| "<li value='#{workflow.id}'>#{workflow.concept.fullname}</li>" }
    render :text => @names.join('')
  end
  
  def states
    if params[:show_non_terminal_states_only].to_s == true.to_s
       @states = ProgramWorkflowState.all(:conditions => ['program_workflow_id = ? AND terminal = 0', params[:workflow]], :include => :concept)
    else
       @states = ProgramWorkflowState.all(:conditions => ['program_workflow_id = ?', params[:workflow]], :include => :concept)
    end
    
    @names = @states.map{|state|
      name = state.concept.concept_names.typed("SHORT").first.name rescue state.concept.fullname
      next if name.blank? 
      "<li value='#{state.id}'>#{name}</li>" unless name == params[:current_state]
    }
    render :text => @names.join('')  
  end

  def update
    flash[:error] = nil

    if request.method == :post
      patient_program = PatientProgram.find(params[:patient_program_id])
      #we don't want to have more than one open states - so we have to close the current active on before opening/creating a new one

      current_active_state = patient_program.patient_states.last
      current_active_state.end_date = params[:current_date].to_date

       # set current location via params if given
      Location.current_location = Location.find(params[:location]) if params[:location]

      patient_state = patient_program.patient_states.build(
        :state => params[:current_state],
        :start_date => params[:current_date])
      if patient_state.save
		    # Close and save current_active_state if a new state has been created
		   current_active_state.save

        if patient_state.program_workflow_state.concept.fullname.upcase == 'PATIENT TRANSFERRED OUT' 
          encounter = Encounter.new(params[:encounter])
          encounter.encounter_datetime = session[:datetime] unless session[:datetime].blank?
          encounter.save

          (params[:observations] || [] ).each do |observation|
            #for now i do this
            obs = {}
            obs[:concept_name] = observation[:concept_name] 
            obs[:value_coded_or_text] = observation[:value_coded_or_text] 
            obs[:encounter_id] = encounter.id
            obs[:obs_datetime] = encounter.encounter_datetime || Time.now()
            obs[:person_id] ||= encounter.patient_id  
            Observation.create(obs)
          end

          observation = {} 
          observation[:concept_name] = 'TRANSFER OUT TO'
          observation[:encounter_id] = encounter.id
          observation[:obs_datetime] = encounter.encounter_datetime || Time.now()
          observation[:person_id] ||= encounter.patient_id
          observation[:value_text] = params[:transfer_out_location_id]
          Observation.create(observation)
        end  

        updated_state = patient_state.program_workflow_state.concept.fullname

		#disabled redirection during import in the code below
		# Changed the terminal state conditions from hardcoded ones to terminal indicator from the updated state object
        if patient_state.program_workflow_state.terminal == 1
          #the following code updates the person table to died yes if the state is Died/Death
          if updated_state.match(/DIED/i)
            person = patient_program.patient.person
            person.dead = 1
            unless params[:current_date].blank?
              person.death_date = params[:current_date].to_date
            end
            person.save

            #updates the state of all patient_programs to patient died and save the
            #end_date of the last active state.
            current_programs = PatientProgram.find(:all,:conditions => ["patient_id = ?",@patient.id])
            current_programs.each do |program|
              if patient_program.to_s != program.to_s
                current_active_state = program.patient_states.last
                current_active_state.end_date = params[:current_date].to_date

                Location.current_location = Location.find(params[:location]) if params[:location]

                patient_state = program.patient_states.build(
                    :state => params[:current_state],
                    :start_date => params[:current_date])
                if patient_state.save
		              current_active_state.save

		          # date_completed = session[:datetime].to_time rescue Time.now()
                date_completed = params[:current_date].to_date rescue Time.now()
                PatientProgram.update_all "date_completed = '#{date_completed.strftime('%Y-%m-%d %H:%M:%S')}'",
                                       "patient_program_id = #{program.patient_program_id}"
                end
             end
            end
          end

          # date_completed = session[:datetime].to_time rescue Time.now()
          date_completed = params[:current_date].to_date rescue Time.now()
          PatientProgram.update_all "date_completed = '#{date_completed.strftime('%Y-%m-%d %H:%M:%S')}'",
                                     "patient_program_id = #{patient_program.patient_program_id}"
        else
          person = patient_program.patient.person
          person.dead = 0
          person.save
          date_completed = nil
          PatientProgram.update_all "date_completed = NULL",
                                     "patient_program_id = #{patient_program.patient_program_id}"
        end
        #for import
         unless params[:location]
            redirect_to :controller => :patients, :action => :programs_dashboard, :patient_id => params[:patient_id]
         else
            render :text => "import suceeded" and return
         end
        
      else
        #for import
        unless params[:location]
          redirect_to :controller => :patients, :action => :programs_dashboard, :patient_id => params[:patient_id],:error => "Unable to update state"
        else
            render :text => "import suceeded" and return
        end
      end
    else
      patient_program = PatientProgram.find(params[:id])
      unless patient_program.date_completed.blank?
        unless params[:location]
            flash[:error] = "The patient has already completed this program!"
       else
          render :text => "import suceeded" and return
       end   
      end
      @patient = patient_program.patient
      @patient_program_id = patient_program.patient_program_id
      program_workflow = ProgramWorkflow.all(:conditions => ['program_id = ?', patient_program.program_id], :include => :concept)
      @program_workflow_id = program_workflow.first.program_workflow_id
      @states = ProgramWorkflowState.all(:conditions => ['program_workflow_id = ?', @program_workflow_id], :include => :concept)
      @names = @states.map{|state|
        concept = state.concept
        next if concept.blank?
        concept.fullname 
      }

      @names = @names.compact unless @names.blank?
      @program_date_completed = patient_program.date_completed.to_date rescue nil
      @program_name = patient_program.program.name
      @current_state = patient_program.patient_states.last.program_workflow_state.concept.fullname if patient_program.patient_states.last.end_date.blank?

      closed_states = []
      current_programs = PatientProgram.find(:all,:conditions => ["patient_id = ?",@patient.id])
      current_programs.each do | patient_program |
        patient_program.patient_states.each do | state |
          next if state.end_date.blank?
          closed_states << "#{state.start_date.to_date}:#{state.end_date.to_date}"
        end
        @invalid_date_ranges = closed_states.join(',')
      end
    end
  end

  # Looks for the most commonly used element in the database and sorts the results based on the first part of the string
  def most_common_program_locations(search)
    return (Location.find_by_sql([
      "SELECT DISTINCT location.name AS name, location.location_id AS location_id \
       FROM location \
       INNER JOIN patient_program ON patient_program.location_id = location.location_id AND patient_program.voided = 0 \
       WHERE location.retired = 0 AND name LIKE ? AND name != '' \
       GROUP BY patient_program.location_id \
       ORDER BY INSTR(name, ?) ASC, COUNT(name) DESC, name ASC \
       LIMIT 10",
       "%#{search}%","#{search}"]) + [Location.current_health_center]).uniq
  end

  def most_common_locations(search)
    return (Location.find_by_sql([
      "SELECT DISTINCT location.name AS name, location.location_id AS location_id \
       FROM location \
       WHERE location.retired = 0 AND name LIKE ? AND name != '' \
       ORDER BY name ASC \
       LIMIT 10",
       "%#{search}%"])).uniq
  end

end
