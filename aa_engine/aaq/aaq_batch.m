classdef aaq_batch < aaq
    % aaq_batch < aaq
    % aa queue processor running batch jobs on a parallel cluster initiated
    % with parcluster.
    %
    % The sequence of method/function calls triggering the execution of a
    % module's code is
    %
    %   runall > add_from_jobqueue > batch_q_job > ...
    %       createJob, createTask | aa_doprocessing_onetask
    % 
    % aaq_batch Properties (*inherited):
    %   pool         - cluster object
    %   QV           - instance of aas_qsubViewerClass (Queue viewer)
    %   *aap         - struct
    %   *isOpen      - logical, flag indicating whether Taskqueue is open
    %   *fatalerrors - logical, flag indicating fatal error
    %   *pausedur    - scalar, duration of pauses between retries of job submission    
    %   *jobqueue    - struct array, composed of 'taskmasks'
    %
    % aaq_batch Methods (*inherited):
    %   close               - Cancel jobs in queue and call superclass' close
    %   runall              - Run all jobs/tasks on the queue
    %   QVUpdate            - Update queue viewer
    %   QVClose             - Close queue viewer
    %   batch_q_job          - Create Job in the pool and task in the job if pool exists, 
    %                         otherwise call aa_doprocessing_onetask
    %   add_from_jobqueue   - Add job to queue by calling batch_q_job and creating jobinfo
    %   remove_from_jobqueue - Remove job from jobqueue, possibly initiating a retry
    %   job_monitor         - Gather job info from the job scheduler
    %   job_monitor_loop    - Run loop gathering job information from the job scheduler.
    %   *save              - save self to file
    %   *emptyqueue        - clear the task queue (set jobqueue to [])
    %   *addtask           - add a task to the task queue
    %   *allocate          - allocate a job from the task queue to a worker
    %   *getjobdescription - return struct task
    
    properties   
        pool = []   % cluster object
        QV = []     % instance of aas_qsubViewerClass (Queue viewer)
    end
    
    properties (Hidden)
        poolConf = cell(1,3)        % cell, pool configuration as in xml parameter file
        jobnotrun = []              % logical array, of same length as .jobqueue in which true indicates that the job has not run
        jobinfo = struct(...        % struct, info on job
            'InputArguments',{},...
            'modulename',{},...
            'jobname',{},...
            'jobpath',{},...
            'JobID',{},...
            'qi',{},...
            'logfile',{},...
            'jobrunreported',{},...
            'state',{},...
            'tic',{},...
            'CPU',{},...            
            'subjectinfo',{}...
            )
        jobretries = []             % array, number of retries of job runs
        waitforalljobs              % logical, true indicating that job queue is fully built, false otherwise
        initialSubmitArguments      % string, 2nd input arg to pool.SubmitArguments (ensures resources, e.g. MAXFILTER license)
        newGenericVersion           % logical, true if pool.IndependentSubmitFcn is empty 
        refresh_waitforjob          % - unused
        refresh_waitforworker       % - unused
    end
    
    methods
        function [obj]=aaq_batch(aap)
            % Look for pool profile, initialize parcluster (if pool profile found)
            obj = obj@aaq(aap);

            global aaworker;
            global aaparallel;
            
            try
                if ~isempty(aap.directory_conventions.poolprofile)
                    % Parse configuration
                    conf = textscan(aap.directory_conventions.poolprofile,'%s','delimiter',':');
                    % ":" in the initial configuration command
                    if numel(conf{1}) > 3 
                        conf{1}{3} = sprintf('%s:%s',conf{1}{3:end});
                        conf{1}(4:end) = [];
                    end
                    for c = 1:numel(conf{1})
                        obj.poolConf(c) = conf{1}(c); 
                    end
                    [poolprofile, obj.initialSubmitArguments] = obj.poolConf{1:2};
                    if isempty(obj.initialSubmitArguments), obj.initialSubmitArguments = ""; end
                    obj.initialSubmitArguments = string(obj.initialSubmitArguments);

                    profiles = parallel.clusterProfiles;
                    if ~any(strcmp(profiles,poolprofile))
                        ppfname = which(spm_file(poolprofile,'ext','.settings'));
                        if isempty(ppfname)
                            aas_log(obj.aap,true,sprintf('ERROR: settings for pool profile %s not found!',poolprofile));
                        else
                            poolprofile = parallel.importProfile(ppfname);
                        end
                    else
                        aas_log(obj.aap,false,sprintf('INFO: pool profile %s found',poolprofile));
                    end
                    obj.pool=parcluster(poolprofile);
                    % set up cluster object (Slurm | Torque | LSF | Generic
                    % | Local), changing aaparallel.numberofworkers
                    obj = obj.clustersetup(true);
                else
                    obj.pool = parcluster('local');
                    % ** no need to set any of aaparallel's values here as
                    % this has been taken care of in aa_doprocessing
                end
                % Note that we're possibly overriding the number of workers
                % that may have been stored in a pool profile
                obj.pool.NumWorkers = aaparallel.numberofworkers;
                obj.pool.JobStorageLocation = aaworker.parmpath;
            catch ME
                aas_log(aap,false,'WARNING: Cluster computing is not supported!');
                aas_log(aap,false,sprintf('\tERROR in %s:\n\tline %d: %s',ME.stack(1).file, ME.stack(1).line, ME.message),aap.gui_controls.colours.warning);
                obj.pool=[];
            end
        end
        
        % =================================================================
        function close(obj)
            % Cancel jobs in queue and call superclass' close
            if ~isempty(obj.pool)
                for j = numel(obj.pool.Jobs):-1:1
                    obj.pool.Jobs(j).cancel;
                end
            end
            close@aaq(obj);
        end
        
        % =================================================================
        % Queue jobs on Qsub:
        %  Queue job
        %  Watch output files
        function runall(obj, dontcloseexistingworkers, waitforalljobs) %#ok<INUSL>
            % Run all jobs/tasks on the queue
            obj.waitforalljobs = waitforalljobs;
            
            global aaworker
            
            % Check number of jobs & monitored files
            njobs=length(obj.jobqueue);
            
            % We have already submitted some of these jobs
            submittedJobs = 1:length(obj.jobnotrun);
            obj.jobnotrun = true(njobs,1);
            obj.jobnotrun(submittedJobs) = false;
            
            % Create a array of job retry attempts (needs to be specific to
            % each module so using dynamic fields with modulename as fieldname.
            % modulename is also saved in jobinfo so is easily retrieved later)
            if ~isempty(obj.jobqueue)
                obj.jobretries = zeros(njobs,1);
                
                if obj.jobqueue(end).k == length(obj.aap.tasklist.main.module)
                    obj.waitforalljobs = true;
                end
            end
            jobqueuelimit = obj.aap.options.aaparallel.numberofworkers;
            printswitches.jobsinq = true; % switches for turning on and off messages
            
            % ** Outermost loop: add jobs to the queue until condition for
            % breaking the loop is met or all jobs/tasks have been
            % accomplished. Realize that due to the inner 'for' loop
            % initially several jobs may be started at once, but that in
            % general the number of jobs started per run of the while loop
            % is highly variable, depending on the status of previously
            % started jobs and their interdependency
            while any(obj.jobnotrun) || (obj.waitforalljobs && ~isempty(obj.jobinfo))
                % Lets not overload the filesystem
                pause(0.1);
                pool_length = length(obj.pool.Jobs);
                nfreeworkers = jobqueuelimit - pool_length;
                
                % Only run if there are free workers, otherwise display
                % message that no workers are available
                % ** ditto
                if nfreeworkers > 0
                    % reset the display command
                    printswitches.nofreeworkers = true; 
                    % Find how many free workers available, then allocate next
                    % batch. Skip section if there are no jobs to run.
                    if any(obj.jobnotrun)
                        if printswitches.jobsinq
                            aas_log(obj.aap, false, sprintf('Jobs in aa queue: %d\n', sum(obj.jobnotrun)))
                            % Don't display again unless queue length changes
                            printswitches.jobsinq = false; 
                        end
                        runjobs = shiftdim(find(obj.jobnotrun))';
                        nfreeworkers = min([nfreeworkers, length(runjobs)]);
                        runjobs = runjobs(1:nfreeworkers);
                        readytorunall = true(size(runjobs));
                        
                        % ** loop through all 'runjobs', see whether they
                        % are ready to run, and if so, run (by adding to
                        % the queue)
                        for i = runjobs
                            rtrind = runjobs == i; % index for readytorunall
                            if (obj.jobnotrun(i))
                                % Find out whether this job is ready to be allocated by
                                % checking dependencies (done_ flags)
                                for j=1:length(obj.jobqueue(i).tobecompletedfirst)
                                    if (~exist(obj.jobqueue(i).tobecompletedfirst{j},'file'))
                                        readytorunall(rtrind) = false;
                                    end
                                end
                                
                                if readytorunall(rtrind)
                                    % Add the job to the queue, and create
                                    % the job info in obj.jobinfo
                                    % ** Here, somewhat hidden from the uninitiated eye, is the
                                    % instruction to run a module's code.
                                    % Chain of calls: add_from_jobqueue > % batch_q_job > createJob, createTask
                                    obj.add_from_jobqueue(i);
                                    printswitches.jobsinq = true;
                                end
                            end
                        end
                        
                        if ~any(readytorunall)
                            % display monitor and update job states
                            aas_log(obj.aap, false, 'Workers available, but no jobs ready to run. Waiting a few seconds...')
                            obj.job_monitor(true);
                            pause(obj.pausedur)
                        else
                            % silently update job states
                            obj.job_monitor(true);
                        end
                    elseif ~isempty(obj.jobinfo)
                        % If no jobs left then monitor and update job states
                        aas_log(obj.aap, false, 'No jobs in the queue, waiting for remaining jobs to complete...')
                        obj.job_monitor_loop;
                    end
                else
                    aas_log(obj.aap, false, 'No free workers available: monitoring the queue...')
                    obj.job_monitor_loop;
                end
                
                % ** inspect status of the jobs submitted above, and update
                % variables and GUI accordingly
                idlist = [obj.jobinfo.JobID];
                for id = idlist
                    JI = obj.jobinfo([obj.jobinfo.JobID] == id);
                    % For clarity use JI.JobID from now on (JI.JobID = id). All
                    % job information is stored in JI, including the main
                    % queue index JI.qi used to refer back to the original
                    % job queue (obj.jobqueue) created when this object was called.
                    
                    Job = obj.pool.Jobs([obj.pool.Jobs.ID] == JI.JobID);
                    if isempty(Job) % cleared by the GUI
                        if obj.QV.isvalid
                            obj.QV.Hold = false;
                        end
                        obj.fatalerrors = true; % abnormal terminations
                        obj.close;
                        return;
                    end
                    Task = Job.Tasks;
                    
                    switch JI.state
                        case 'pending'
                            if isempty(JI.tic)
                                JI.tic = tic; 
                                obj.jobinfo([obj.jobinfo.JobID] == JI.JobID).tic = JI.tic;
                            end
                            t = toc(JI.tic);
                            % aa to switch this on/off or extend the time? On very busy
                            % servers this might cause all jobs to be
                            % perpetually deleted and restarted.
                            if (obj.aap.options.aaworkermaximumretry > 1) && (t > obj.aap.options.aaworkerwaitbeforeretry) % if job has been pending for more than N seconds
                                obj.remove_from_jobqueue(JI.JobID, true); % 2nd argument = retry
                            end
                            
                        case 'failed' % failed to launch
                            msg = sprintf(...
                                ['Failed to launch (Licence?)!\n'...
                                'Check <a href="matlab: open(''%s'')">logfile</a>\n'...
                                'Queue ID: %d | batch ID %d | Subject ID: %s'],...
                                JI.logfile, JI.qi, JI.JobID, JI.subjectinfo.subjname);
                            % If there is an error, it is fatal...
                            
                            fatalerror = obj.jobretries(JI.qi) > obj.aap.options.aaworkermaximumretry; % will be true if max retries reached
                            if fatalerror
                                msg = sprintf('%s\nMaximum retries reached\n', msg);
                                aas_log(obj.aap,fatalerror,msg,obj.aap.gui_controls.colours.error)
                            end
                            
                            % This won't happen if the max retries is
                            % reached, allowing debugging
                            obj.remove_from_jobqueue(JI.JobID, true); % 2nd argument = retry
                            
                        case 'inactive'
                            if isempty(JI.tic)
                                obj.jobinfo([obj.jobinfo.JobID] == JI.JobID).tic = tic;
                                aas_log(obj.aap,false,sprintf('Job%d (%s) seems to be inactive',JI.JobID,JI.modulename),obj.aap.gui_controls.colours.warning)
                            else
                                t = round(toc(JI.tic));
                                % aa to switch this on/off or extend the time? On very busy
                                % servers this might cause all jobs to be
                                % perpetually deleted and restarted.
                                aas_log(obj.aap,false,sprintf('Job%d (%s) seems to be inactive for %d seconds',JI.JobID,JI.modulename,t),obj.aap.gui_controls.colours.warning)
                                if (obj.aap.options.aaworkermaximumretry > 1) && (t > obj.aap.options.aaworkerwaitbeforeretry) % if job has been sleeping for more than N seconds
                                    if obj.jobretries(JI.qi) <= obj.aap.options.aaworkermaximumretry
                                        obj.remove_from_jobqueue(JI.JobID, true); % 2nd argument = retry
                                        aas_log(obj.aap,false,'    Job has been restarted',obj.aap.gui_controls.colours.warning)
                                    else
                                        aas_log(obj.aap,true,sprintf('    Number of attempts for job%d has reached the limit of %d!\n Check <a href="matlab: open(''%s'')">logfile</a>\n',JI.JobID,obj.aap.options.aaworkermaximumretry,JI.logfile),obj.aap.gui_controls.colours.warning)
                                    end
                                end
                            end
                            
                        case 'cancelled' % cancelled
                            aas_log(obj.aap,true,sprintf('Job%d had been cancelled by user!\n Check <a href="matlab: open(''%s'')">logfile</a>\n',JI.JobID,JI.logfile),obj.aap.gui_controls.colours.warning)
                            
                        case 'finished' % without error
                            if isprop(Task,'StartDateTime')
                                startTime = char(Task.StartDateTime);
                                finishTime = char(Task.FinishDateTime);
                            elseif isprop(Task,'StartTime')
                                startTime = Task.StartTime;
                                finishTime = Task.FinishTime;
                            else
                                aas_log(obj.aap,true,'Time-related property of Task class not found!')
                            end
                            if isempty(finishTime)
                                continue
                            end
                            msg = sprintf('JOB %d: \tMODULE %s \tON %s \tSTARTED %s \tFINISHED %s \tUSED %s.',...
                                JI.JobID,JI.modulename,JI.jobname,startTime,finishTime,aas_getTaskDuration(Task));
                            aas_log(obj.aap,false,msg,obj.aap.gui_controls.colours.completed);
                            
                            % Also save to file with module name attached!
                            fid = fopen(fullfile(aaworker.parmpath,'batch','time_estimates.txt'), 'a');
                            fprintf(fid,'%s\n',msg);
                            fclose(fid);
                            
                            obj.remove_from_jobqueue(JI.JobID, false);
                            
                        case 'error' % running error
                            
                            % Check whether the error was a "file does not
                            % exist" type. This can happen when a dependent
                            % folder is only partially written upon job execution.
                            % jobinfo etc is indexed by the job ID so get i from jobinfo.
                            
                            if obj.jobretries(JI.qi) <= obj.aap.options.aaworkermaximumretry
                                msg = sprintf(['%s\n\n JOB FAILED WITH ERROR: \n %s',...
                                    ' \n\n Waiting a few seconds then trying again',...
                                    ' (%d tries remaining for this job)\n'...
                                    'Press Ctrl+C now to quit, then run aaq_qsub_debug()',...
                                    ' to run the job locally in debug mode.\n'],...
                                    Task.Diary, Task.ErrorMessage, obj.aap.options.aaworkermaximumretry - obj.jobretries(JI.qi));
                                aas_log(obj.aap, false, msg);
                                obj.jobnotrun(JI.qi) = true;
                                obj.remove_from_jobqueue(JI.JobID, true);
                                pause(obj.pausedur)
                            else
                                msg = sprintf('Job%d on <a href="matlab: cd(''%s'')">%s</a> had an error: %s\n',JI.JobID,JI.jobpath,JI.jobname,Task.ErrorMessage);
                                for e = 1:numel(Task.Error.stack)
                                    % Stop tracking to internal
                                    if strfind(Task.Error.stack(e).file,'distcomp'), break, end
                                    msg = [msg sprintf('<a href="matlab: opentoline(''%s'',%d)">in %s (line %d)</a>\n', ...
                                        Task.Error.stack(e).file, Task.Error.stack(e).line,...
                                        Task.Error.stack(e).file, Task.Error.stack(e).line)];
                                end
                                % If there is an error, it is fatal...
                                
                                obj.fatalerrors = true;
                                obj.jobnotrun(JI.qi) = true;
                                aas_log(obj.aap,true,msg,obj.aap.gui_controls.colours.error)
                            end
                        otherwise % running
                            obj.jobinfo([obj.jobinfo.JobID] == JI.JobID).tic = [];
                            % aas_log(obj.aap,false,sprintf('Job%d (%s) is running at %3.1f %%%%CPU',JI.JobID,JI.modulename,CPU),obj.aap.gui_controls.colours.info)
                    end
                end
                
                obj.QVUpdate;
            end
            
        end
        
        % =================================================================
        function QVUpdate(obj)
            % Update queue viewer 
            if obj.aap.options.aaworkerGUI
                % queue viewer
                if ~isempty(obj.pool)
                    if ~isempty(obj.QV) && ~obj.QV.isvalid % started but killed
                        return
                    end
                    if (isempty(obj.QV) || ~obj.QV.OnScreen) % not started or closed
                        % ** create queue viewer class instance
                        obj.QV = aas_qsubViewerClass(obj);
                        obj.QV.Hold = true;
                        obj.QV.setAutoUpdate(false);
                    else
                        obj.QV.UpdateAtRate;
                        if obj.waitforalljobs
                            obj.QV.Hold = false;
                        end
                    end
                end
            end
        end
        
        % =================================================================
        function QVClose(obj)
            % Close queue viewer
            if obj.aap.options.aaworkerGUI
                if ~isempty(obj.QV) && obj.QV.isvalid
                    obj.QV.Close;
                    obj.QV.delete;
                    obj.QV = [];
                end
            end
        end
        
        % =================================================================
        function batch_q_job(obj,job)
            % Create batch job in the pool if pool exists, otherwise call
            % aa_doprocessing_onetask
            global aaworker
            global aacache
            aaworker.aacache = aacache;
            [~, reqpath] = aas_cache_get(obj.aap,'reqpath','system');
            % Let's store all our batch thingies in one particular directory
            batchpath=fullfile(aaworker.parmpath,'batch');
            aas_makedir(obj.aap,batchpath);
            cd(batchpath);
            % Submit the job
            if ~isempty(obj.pool)
                % New version (Dec 2020)
                % Notes:
                % 1. In the spirit of 'Innocent until proven guilty' we
                % don't implement fallbacks for the case of unsuccessful
                % submission of the batch job (we'd rather ensure
                % beforehand that the parallel cluster is fully functional)
                % 2. batch is likely not faster than direct calls to
                % createJob and createTask as in the original
                % implementation, but the code is simpler
                % 3. if AutoAttachFiles is true, code called by the
                % batch function, namely
                % (AbstractBatchHelper/iCalculateTaskDependencies)
                % will spend an inordinate amout of time dealing
                % with task dependencies (paths), so unless there
                % is a compelling reason to do so, don't auto
                % attach files
                % 4. Matlab's interactive Job Monitor will not show
                % the jobs unless the pool in which batch operates
                % has been made the default
                batch(obj.pool, @aa_doprocessing_onetask, 1, ...
                    {obj.aap, job.task, job.k, job.indices, aaworker}, ...
                    'AutoAttachFiles', false, ...
                    'AutoAddClientPath', false, ...
                    'AdditionalPaths', reqpath,...
                    'CaptureDiary', true);
            else
                aa_doprocessing_onetask(obj.aap,job.task,job.k,job.indices);
            end
        end
        
        % =================================================================
        function add_from_jobqueue(obj, i)
            % Add job to queue by calling batch_q_job and creating jobinfo
            global aaworker
            % Add a job to the queue
            job=obj.jobqueue(i);
            
            % ** call batch_q_job, which does the heavy lifting (batch)
            obj.batch_q_job(job);
            
            % -- Create struct ji, the job info for referencing later:
            % - clean up done jobs to prevent IDs occuring twice
            latestjobid = max([obj.pool.Jobs.ID]);
            Task = obj.pool.Jobs([obj.pool.Jobs.ID] == latestjobid).Tasks;
            % if any jobs have been run yet...
            if ~all(obj.jobnotrun(i)) 
                % remove previous job with same ID
                obj.jobinfo([obj.jobinfo.JobID] == latestjobid) = []; 
            end
            % - assemble ji 
            ji.InputArguments = {[], job.task, job.k, job.indices, aaworker};
            ji.modulename = obj.aap.tasklist.main.module(ji.InputArguments{3}).name;
            
            aap = aas_setcurrenttask(obj.aap,job.k);
            ji.jobname = '';
            for iind = numel(job.indices):-1:1
                switch iind
                    case 2
                        ji.jobname = aas_getsessdesc(aap,job.indices(iind-1),job.indices(iind));
                    case 1
                        ji.jobname = aas_getsubjdesc(aap,job.indices(iind));
                end
                if ~isempty(ji.jobname)
                    break; 
                end
            end
            
            [~, ji.jobpath]=aas_doneflag_getpath_bydomain(obj.aap,job.domain,job.indices,job.k);
            ji.JobID = latestjobid;
            ji.qi = i;
            ji.logfile = fullfile(obj.pool.JobStorageLocation, Task.Parent.Name, [Task.Name '.log']);
            ji.jobrunreported = false;
            ji.state = 'pending';
            ji.tic = tic;
            ji.CPU = [];
            
            if strcmp(job.domain, 'study')
                ji.subjectinfo = struct('subjname', 'ALL SUBJECTS');
            else
                ji.subjectinfo = obj.aap.acq_details.subjects(job.indices(1));
            end
            
            % - append ji to jobinfo 
            obj.jobinfo = [obj.jobinfo, ji];
            obj.jobnotrun(i) = false;
            obj.jobretries(i) = obj.jobretries(i) + 1;
            aas_log(obj.aap, false, sprintf('Added job %s with batch ID %3.1d | Subject ID: %s | Execution: %3.1d | Jobs submitted: %3.1d',...
                ji.modulename, ji.JobID, ji.subjectinfo.subjname, obj.jobretries(i), length(obj.pool.Jobs)))
        end
        
        % =================================================================
        function remove_from_jobqueue(obj, ID, retry)
            % Remove job from jobqueue, possibly initiating a retry
            
            % exact opposite of method add_from_jobqueue
            % Need to use JobID from obj.pool here instead of the jobqueue
            % index (obj.jobinfo.qi), which is not unique if uncomplete
            % jobs exist from previous modules
            
            ind = [obj.jobinfo.JobID] == ID;
            ji = obj.jobinfo(ind); % get job info struct
            
            % Backup Job Diary
            src = sprintf('%s/Job%d', obj.pool.JobStorageLocation, ji.JobID);
            dest = sprintf('%s_bck/Job%d', obj.pool.JobStorageLocation, ji.JobID);
            if exist(src,'dir')
                mkdir(dest);
                copyfile(src, dest);
            end
            
            % Clear job
            obj.jobinfo(ind) = [];
            obj.pool.Jobs([obj.pool.Jobs.ID] == ji.JobID).delete;
            
            % If retry requested, then reset jobnotrun and increment retry
            % counter
            if retry
                % Remove files from previous execution
                if exist(ji.jobpath,'dir')
                    rmdir(ji.jobpath,'s'); 
                end
                % Add to jobqueue
                obj.jobnotrun(ji.qi)=true;
            end
        end
        
        % =================================================================
        function states = job_monitor(obj, printjobs)
            % Gather job information from the job scheduler.
            % This can be slow depending on the size of the pool.
            % INPUT
            % printjobs [true|false]: print job information to the screen.
            % OUTPUT
            % states: cell array of states (character)
            %   {'running' | 'failed' | 'error' | 'finished'}
            % obj.jobinfo is also updated with the state information
            if nargin < 2
                printjobs = false;
            end
            if ~printjobs
                % This function might take a while. Let user know what's happening
                aas_log(obj.aap, false, 'Retrieving job information')
            end
            states = cell(1,numel(obj.jobinfo));
            jobids = [obj.pool.Jobs.ID];
            for id = shiftdim(jobids)'
                Jobs = obj.pool.Jobs(jobids == id);
                if isempty(Jobs) % cleared by the GUI
                    if obj.QV.isvalid
                        obj.QV.Hold = false;
                    end
                    obj.fatalerrors = true; % abnormal terminations
                    obj.close;
                    return;
                end
                jobind = [obj.jobinfo.JobID] == id;
                
                % If the job ID does not exist, jobinfo is not up-to-date
                % Assigning failed will cause the state handler to restart
                % the job without trying to remove it from pool.
                if any(jobind)
                    obj.jobinfo(jobind).state = Jobs.State;
                else
                    aas_log(obj.aap,false,sprintf('WARNING: Job %d not found in aa queue!',id));
                    %                     obj.jobinfo(jobind).state = 'failed';
                end
                
                % Double check that finished jobs do not have an error in the Task object
                if any(jobind)
                    switch obj.jobinfo(jobind).state
                        case 'running'
                            if isfield(obj.aap.options,'aaworkercheckCPU') && obj.aap.options.aaworkercheckCPU
                                w = []; retry = 0;
                                while ~isobject(w) && retry < obj.aap.options.aaworkermaximumretry % may not have been updated, yet - retry
                                    retry = retry + 1;
                                    w = Jobs.Tasks.Worker;
                                    pause(1);
                                end
                                if isobject(w)
                                    [~, txt] = system(sprintf('ssh %s top -p %d -bn1 | tail -2 | head -1 | awk ''{print $9}''',w.Host,w.ProcessId)); % 9th column of top output
                                    obj.jobinfo(jobind).CPU = str2double(txt);
                                else
                                    aas_log(obj.aap,false,sprintf('WARNING: Worker information of Job %d not found!',id));
                                    obj.jobinfo(jobind).CPU = [];
                                end
                            end
                            if ~isempty(obj.jobinfo(jobind).CPU) && (obj.jobinfo(jobind).CPU < 10) % assume it is processed when %CPU > 10
                                obj.jobinfo(jobind).state = 'inactive';
                            end
                        case 'finished'
                            if ~isempty(Jobs.Tasks.Error)
                                switch Jobs.Tasks.Error.identifier
                                    case 'parallel:job:UserCancellation'
                                        obj.jobinfo(jobind).state = 'cancelled';
                                    otherwise
                                        % Check if done flag exists.
                                        % Commented out. File system not always up to date and reliable.
                                        % if ~exist(obj.jobqueue(obj.jobinfo(jobind).qi).doneflag, 'file')
                                        obj.jobinfo(jobind).state = 'error';
                                end
                            end
                    end
                end
            end
            
            states = {obj.jobinfo.state};
            
            if printjobs
                Nfinished = sum(strcmp(states,'finished'));
                Nqueued  = sum(strcmp(states,'queued'));
                Npending = sum(strcmp(states,'pending'));
                Nfailed = sum(strcmp(states,'failed'));
                Nerror    = sum(strcmp(states,'error'));
                Nrunning  = sum(strcmp(states,'running'));
                Ninactive  = sum(strcmp(states,'inactive'));
                msg = sprintf('Running %3d | Queued %3d | Pending %3d | Finished %3d | Inactive %3d | Failed %3d | Error %3d',...
                    Nrunning, Nqueued, Npending, Nfinished, Ninactive, Nfailed, Nerror);
                aas_log(obj.aap,false,msg);
            end
            
            obj.QVUpdate;
        end
        
        % =================================================================
        function job_monitor_loop(obj)
            % Run loop gathering job information from the job scheduler.
            while true
                states = obj.job_monitor(true); % states are also in e.g. obj.jobinfo(i).state
                if any(strcmp(states, 'finished')) || any(strcmp(states, 'error')) || any(strcmp(states, 'failed')) || any(strcmp(states, 'cancelled')) || any(strcmp(states, 'inactive'))
                    break;
                else
                    pause(10);
                    % backspaces to remove the last iteration (93+1)
                    fprintf(repmat('\b',[1 94]))
                end
            end
        end
    end
end
