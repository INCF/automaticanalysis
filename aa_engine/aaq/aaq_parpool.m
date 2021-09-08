classdef aaq_parpool < aaq
    % aaq_parpool < aaq
    % aa queue processor using Matlab's parfeval to run tasks on a pool of
    % Matlab workers which are started and reserved via parpool prior to
    % any module computation.
    %
    % The advantages compared to other queue processors are in terms of the
    % availability of workers:
    %  i) short latency (because Matlab processes don't need to be started
    %     up for each task)
    % ii) Workers are reserved, so their availability is guaranteed
    %
    % Compared to other queue processors with parallelisation, aaq_parpool
    % features an alternative, faster computation of job dependencies,
    % which rather than relying on 'job done' flags in the form of files
    % written into each module's working directory, keeps track of jobs via
    % variables within the client session's workspace. For this to work, 
    % the taskqueue needs to be fully built (in aa_doprocessing); this is
    % checked by input arg 'waitforalljobs' of method runall.
    %
    % aaq_parpool lends itself to analyses with many tasks of little
    % complexity, and/or computations on individual multicore machines, or
    % other environments in which blocking CPUs is not an issue.
    
    properties
        pool            = [];    % cluster object
        doHandlePool    = false; % logical, true indicating that class handles parpool
        parpool_path    = [];    % subdirectory for storing job diaries (and possibly other parallel-pool-related files in the future)
        jobcount        = 0;     % counter for jobs in pipeline
        FFuture         = parallel.FevalFuture  % instance of parallel.FevalFuture
    end
    
    properties (Hidden)                     % FEJIT ('for each job in taskqueue'): arrays the same size as taskqueue
        jobStudyPaths           = {}        % cell array, actualised studypath (FEJIT)
        jobReadyToGo            = []        % double array, indexes of jobs ready to be processed
        isJobNotRun             = false(0)  % logical array, true indicating job has not run (FEJIT)
        jobDoneFlag             = {}        % cell array, copy of taskmask.doneflag (FEJIT)
        isJobDoneFlag           = false(0)  % logical array, true if doneflag file exists (FEJIT)
        jobDepOn                = {}        % cell array of double arrays, indexes of jobs the actual job depends on (FEJIT)
        jobDepOf                = {}        % cell array of double arrays, indexes of jobs depending on the actual job (FEJIT)
        numJobDepOn             = []        % double array, no. of jobs the actual job depends on (FEJIT)
        aaworker                = []        % copy of global aaworker struct
        workerstatus            = {}        % cell array of chars indicating worker status (for each worker)
        % Torque-only
        initialSubmitArguments  = '' % additional arguments to use when submitting jobs
    end
    
    methods
        function [obj]=aaq_parpool(aap)
            % Constructor: setting up engine
            global aaparallel
            global aaworker
            obj.aap=aap;
            obj.aaworker = aaworker;
            
            obj.parpool_path=fullfile(obj.aaworker.parmpath,'parpool');
            if ~exist(obj.parpool_path,'dir')
                aas_makedir(obj.aap,obj.parpool_path);
            end
            
            if ~aas_matlabpool('isopen')
                if ~isempty(aap.directory_conventions.poolprofile)
                    profiles = parallel.clusterProfiles;
                    if ~any(strcmp(profiles,aap.directory_conventions.poolprofile))
                        ppfname = which(spm_file(aap.directory_conventions.poolprofile,'ext','.settings'));
                        if isempty(ppfname)
                            aas_log(aap,true,sprintf('ERROR: settings for pool profile %s not found!',aap.directory_conventions.poolprofile));
                        else                            
                            obj.pool=parcluster(parallel.importProfile(ppfname));
                        end
                    else
                        aas_log(aap,false,sprintf('INFO: pool profile %s found',aap.directory_conventions.poolprofile));
                        obj.pool=parcluster(aap.directory_conventions.poolprofile);
                    end
                    % set up cluster object (Slurm | Torque | LSF | Generic
                    % | Local) without changing aaparallel.numberofworkers
                    obj = obj.clustersetup(false);
                else
                    obj.pool = parcluster('local');
                end
                obj.pool.NumWorkers = aaparallel.numberofworkers;
                obj.pool.JobStorageLocation = obj.aaworker.parmpath;
                % Note that below we're possibly overriding the number of
                % workers that may have been stored in a pool profile
                C = aas_matlabpool(obj.pool,obj.pool.NumWorkers);
                if ~isempty(C)
                    C.IdleTimeout = aaparallel.walltime*60; 
                end
                obj.doHandlePool = true;                
            end
        end

        
        function close(obj)
            % Close matlabpool and invoke superclass' close function.
            if obj.doHandlePool
                aas_matlabpool('close'); 
            end
            close@aaq(obj);
        end
        
        
        function addtask(obj,taskmask)
            % Add a task to the task queue.
            % Adds to the parent class's method by scanning the
            % dependencies of the new module.
            obj=addtask@aaq(obj,taskmask);
            job_ix=length(obj.jobqueue);
            obj.isJobNotRun(job_ix)=true;
            
            % For better performance, make a list of all dependencies and
            % refer to them by index 
            % Removes need for endless done flag file checking
            obj.jobDepOf{job_ix}=[];
            obj.jobDepOn{job_ix}=[];
            obj.numJobDepOn(job_ix)=0;
            
            % Store this task as a future dependency of others
            obj.jobDoneFlag{job_ix}=taskmask.doneflag;
            obj.isJobDoneFlag(job_ix)=exist(taskmask.doneflag,'file');
            obj.jobStudyPaths{job_ix}=aas_getstudypath(obj.aap,taskmask.k);
            
            % Go through each dependency of this task and find the index of
            % that
            for tbcfind=1:length(obj.jobqueue(job_ix).tobecompletedfirst)
                % Find or put this dependency in a list
                df=obj.jobqueue(job_ix).tobecompletedfirst{tbcfind};
                depind=find(strcmp(df,obj.jobDoneFlag));
                if isempty(depind)
                    aas_log(aap,true,sprintf('Dependency %s of %s not found.',df,taskmask.doneflag));
                end
                
                % Only record dependencies that haven't already been
                % satisfied
                if ~obj.isJobDoneFlag(depind)
                    obj.jobDepOn{job_ix}(end+1)=depind;
                    obj.numJobDepOn(job_ix)=obj.numJobDepOn(job_ix)+1;
                    obj.jobDepOf{depind}(end+1)=job_ix;
                end
            end
            
            % Add it to the jobReadyToGo queue if appropriate
            if obj.numJobDepOn(job_ix)==0
                obj.jobReadyToGo=[obj.jobReadyToGo, job_ix];
            end
        end

        
        function jobTable = updateJobTable(obj, jobTable)
            % Update jobTable by copying values of obj.FFuture to it
            jobTable.state = {obj.FFuture.State}';
            jobTable.error = {obj.FFuture.Error}';
        end        
        
        
        function jobTable = jobTableUpdate2base(obj, jobTable)
            % Update jobTable and assign it to base workspace (for debugging)
            jobTable = obj.updateJobTable(jobTable);
            assignin('base', 'jobTable', jobTable);
        end
        
        
        function jobname = getJobName(obj, job)
            % Retrieve detailed job name
            aap = aas_setcurrenttask(obj.aap,job.k);
            jobname = '';
            for iind = numel(job.indices):-1:1
                switch iind
                    case 2
                        jobname = aas_getsessdesc(aap,job.indices(iind-1),job.indices(iind));
                    case 1
                        jobname = aas_getsubjdesc(aap,job.indices(iind));
                end
                if ~isempty(jobname)
                    break;
                end
            end
        end
        
        
        function reportProblem(obj, isFatal, badIx)
            % Report error details on the command line.
            % - isFatal is a logical indicating whether an error should be
            %   produced (via aas_log)
            % - badIx must be a logical array pointing to the offending 
            %   entry or entries in obj.jobqueue / obj.FFuture
            % propagate fatality
            obj.fatalerrors = isFatal;
            % in case two or more errors should have occurred in parallel, 
            % display all
            badIx = find(badIx);
            for bix = 1:numel(badIx)
                % the job that caused trouble
                job = obj.jobqueue(badIx(bix));
                % the corresponding FevalFuture
                ff = obj.FFuture(badIx(bix));
                % retrieve path of this particular job
                [~, jobpath]=aas_doneflag_getpath_bydomain(obj.aap, job.domain, job.indices, job.k);
                % retrieve job name
                jobname = obj.getJobName(job);
                % finally, assemble error message
                msg = sprintf('Job%d on <a href="matlab: cd(''%s'')">%s</a> had an error:\n',...
                    job.k, jobpath, jobname);
                % ** note that the error report will contain links to
                % temporary copies of code files used by the workers, not
                % to the original code, so the user should NOT edit these
                msg = [msg, ff.Error.getReport('extended', 'hyperlinks', 'on')];
                aas_log(obj.aap, false, msg);
            end
            msg = ['For detailed debugging in the context of job dependencies\n', ...
                ' see jobTable, a variable dumped to the base workspace'];
            aas_log(obj.aap, isFatal, msg);
        end
        
        
        function runall(obj, ~, waitforalljobs)
            % Run all jobs on the queue using parfeval.
            % 'waitforalljobs' is a logical, true indicating that the job
            % queue is fully built, false otherwise.

            % if true, any failed or canceled job will trigger an error
            DO_STRICT_CHECKS = true;
            % Copy current value of global variable aacache to obj.aaworker
            % because workers cannot 'see' the values of client global
            % variables
            global aacache
            obj.aaworker.aacache = aacache;
            
            % Run only if the queue is fully built
            if waitforalljobs
                if ~isempty(obj.jobqueue)
                    numJobs = length(obj.jobqueue);
                    isJobCanceled = false(1, numJobs);
                    % preallocate array of future objects
                    obj.FFuture(1:numJobs) = parallel.FevalFuture;
                    % create table from obj.jobqueue & update
                    jobTable = obj.jobqueue2table();
                    jobTable = obj.updateJobTable(jobTable);
                    execCounter = 0;
                    while any(obj.isJobNotRun)
                        % obj.jobReadyToGo will be reconstructed below,
                        % each time after a job has successfully finished
                        jobreadylist=obj.jobReadyToGo;
                        obj.jobReadyToGo=[];
                        % check uniqueness 
                        if numel(unique(jobreadylist)) ~= numel(jobreadylist)
                            aas_log(obj.aap, true, sprintf('ERROR:internal:jobReadyToGo contains duplicates'));
                        end
                        
                        for jix = jobreadylist(:)'
                            job=obj.jobqueue(jix); 
                            % avoid any potential confusion with global var
                            % aaworker by appending _copy to variable name
                            aaworker_copy = obj.aaworker;
                            aaworker_copy.logname = fullfile(obj.parpool_path,sprintf('Job%05d_diary.txt',jix));
                            % protocol order of current job
                            execCounter = execCounter + 1;
                            jobTable.execorder(jix) = execCounter;
                            % announce job
                            msg = sprintf('Parallel eval submission of job #%d (#%d on task queue): %s using module %s', ...
                                execCounter, jix, obj.getJobName(job), job.stagename);
                            aas_log(obj.aap, false, msg);
                            % *** parfeval ***
                            obj.FFuture(jix) = parfeval(aas_matlabpool('getcurrent'), ...
                                @aa_doprocessing_onetask, 1, ...
                                obj.aap, job.task, job.k, job.indices, aaworker_copy);
                        end
                        
                        % Fetch any result that may be available:
                        % 1. Note redefinition of jix
                        % 2. fetchNext is the idiomatic way of retrieving a
                        % subset of parfeval'd results - which is currently
                        % not really needed in aa because all results are
                        % written to disk anyways, but may be required in
                        % the future upon further development. Also,
                        % fetchNext sets the 'Read' property of the future,
                        % so is useful for checking the state of affairs.
                        % fetchNext expects array of futures obj.FFuture to be
                        % completely parfeval'd, that is, all jobs must be
                        % different from 'unavailable', the default state
                        % upon preallocation of obj.FFuture. Matlab will
                        % produce an error if that is not the case.
                        % However, due to the dependencies among jobs we
                        % cannot submit them all at once but instead have
                        % to submit them in succession (this is what the
                        % dependency calculation is all about). Hence, we
                        % cannot just
                        %   fetchNext(obj.FFuture)
                        % but instead need to index the entries in
                        % obj.FFuture which are anything but 'unavailable'.
                        % Furthermore, and obviously, we need to check
                        % whether the job ran successfully.
                        
                        % identify jobs which have finished and not been
                        % read, so in principle are ready to be fetched
                        isJobToBeFetched = strcmp({obj.FFuture.State}, 'finished') & ~[obj.FFuture.Read];

                        % of those, kick the ones having been canceled
                        % (which are also in state 'finished' but have a
                        % nonempty Error property (which we unfortunately
                        % have to query in a loop))
                        for ix = 1:numel(isJobToBeFetched)
                            if isJobToBeFetched(ix) && ~isempty(obj.FFuture(ix).Error)
                                isJobCanceled(ix) = true;
                                isJobToBeFetched(ix) = false;
                            end
                        end
                        
                        if DO_STRICT_CHECKS
                            % in case of any failed job, save jobTable to
                            % base workspace and trigger an error
                            badIx = strcmp({obj.FFuture.State}, 'failed');
                            if any(badIx)
                                jobTable = obj.jobTableUpdate2base(jobTable);
                                obj.reportProblem(true, badIx);
                            end
                            % same for canceled job
                            if any(isJobCanceled)
                                jobTable = obj.jobTableUpdate2base(jobTable);
                                obj.reportProblem(true, isJobCanceled);
                            end
                        end
                        
                        % fetch results (aap) and update state variables
                        for jix = find(isJobToBeFetched(:)')
                            [~, fetched_aap] = fetchNext(obj.FFuture(jix));
                            obj.isJobNotRun(jix)=false;
                            % Remove current job as a dependency from all
                            % of the stages dependent on the stage that has
                            % just completed
                            for depoflist=1:length(obj.jobDepOf{jix})
                                deponmask=obj.jobDepOf{jix}(depoflist);
                                obj.jobDepOn{deponmask}(obj.jobDepOn{deponmask}==jix)=[];
                                obj.numJobDepOn(deponmask)=obj.numJobDepOn(deponmask)-1;
                                obj.jobReadyToGo=[obj.jobReadyToGo, deponmask(obj.numJobDepOn(deponmask)==0)];
                            end
                        end
                        % canceled jobs will not change their isJobNotRun
                        % flag, so could potentially cause an infinite loop 
                        % (in case their non-completion did not trigger an
                        % error anyway), so prevent this from happening
                        % once all jobs are 'finished' (i.e. succeeded or
                        % were canceled)
                        if all(strcmp({obj.FFuture.State}, 'finished')) && any(isJobCanceled)
                            jobTable = obj.jobTableUpdate2base(jobTable);
                            obj.reportProblem(false, isJobCanceled);
                            break
                        end
                        % similarly, if at least one job is 'failed' and
                        % the rest is 'finished', notify user and break the
                        % loop
                        badIx = strcmp({obj.FFuture.State}, 'failed');
                        if any(badIx) && all(contains({obj.FFuture.State}, {'finished', 'failed'}))
                            jobTable = obj.jobTableUpdate2base(jobTable);
                            obj.reportProblem(false, badIx);
                            break
                        end
                        % report
                        for jix = find(isJobToBeFetched(:)')
                            ff = obj.FFuture(jix);
                            msg = sprintf('QUEUED_JOB %d: \tMODULE %s \tON %s \tSTARTED %s \tFINISHED %s \tUSED %s.',...
                                jix, obj.jobqueue(jix).stagename, obj.getJobName(obj.jobqueue(jix)), ff.CreateDateTime, ff.FinishDateTime, ff.FinishDateTime - ff.CreateDateTime);
                            aas_log(fetched_aap, false, msg, obj.aap.gui_controls.colours.completed);
                        end
                        % brief pause to prevent the while loop from
                        % consuming too many resources
                        pause(0.5)
                    end
                    % wrap-up:
                    if waitforalljobs == 1
                        obj.emptyqueue;
                    end
                    % ensure we do not leave any futures running when done
                    cancel(obj.FFuture);
                    % update jobTable and assign to base workspace
                    obj.jobTableUpdate2base(jobTable);
                    if obj.fatalerrors
                        aas_log(obj.aap, true, 'Fatal errors executing jobs.','Errors');
                    end
                end
            end
        end
    end
    
end