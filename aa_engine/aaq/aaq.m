classdef aaq < handle
    % aaq < handle  aa queue processor base class
    %
    % aaq Properties:
    %   aap         - struct
    %   isOpen      - logical, flag indicating whether Taskqueue is open
    %   fatalerrors - logical, flag indicating fatal error
    %   jobqueue    - struct array, composed of 'taskmasks' (input arg to
    %                 method addtask)
    % aaq Methods:
    %   close             - close taskqueue (set .isOpen to false)
    %   save              - save self to file
    %   emptyqueue        - clear the task queue (set jobqueue to [])
    %   addtask           - add a task to the task queue
    %   allocate          - allocate a job from the task queue to a worker
    %   getjobdescription - return struct task
    %   jobqueue2table    - create jobTable from jobqueue
    %   runall            - sequentially call aa_doprocessing_onetask on all jobs in queue (no parallelism)

    properties
        aap
        isOpen      = false
        fatalerrors = false 
        jobqueue    = []
    end
    
    methods
        function obj=aaq(aap)
            % If input arg aap is given, assign to property aap, and set isOpen to true
            if (exist('aap','var'))
                obj.aap=aap;
            end
            obj.isOpen = true;
        end
        
        % ==============================
        function close(obj)
            % Close task queue (set isOpen property to false)
            aas_log(obj.aap,false,'Taskqueue is closed!');
            obj.isOpen = false;
        end
        
        % ==============================
        function save(obj,fn)
            % Save self to file
            jobqueue=obj.jobqueue;
            aap=obj.aap;
            save(fn,'jobqueue','aap')
        end
        
        % ==============================
        function obj=emptyqueue(obj)
            % Set jobqueue to []
            obj.jobqueue=[];
        end
        
        % ==============================
        function obj=addtask(obj,taskmask)
            % Append element (taskmask) to jobqueue
            
            % Delete any to be completed first that have already been done
            tbcf={};
            for ind=1:length(taskmask.tobecompletedfirst)
                if (~aas_doneflagexists(obj.aap,taskmask.tobecompletedfirst{ind}))
                    tbcf{end+1}=taskmask.tobecompletedfirst{ind};
                end
            end
            taskmask.tobecompletedfirst=tbcf;
            
            obj.jobqueue=[obj.jobqueue,taskmask];
        end
        
        % ==============================
        function [obj, couldbeallocated]=allocate(obj,i,highmem)
            % Allocate a job from the task queue to a worker
            global aaparallel;
            k=obj.jobqueue(i).k;
            [~, stagename]=fileparts(obj.aap.tasklist.main.module(k).name);
            try
                specialrequirements=obj.aap.tasksettings.(stagename)(obj.aap.tasklist.main.module(k).index).specialrequirements;
                %    specialrequirements={obj.aap.schema.tasksettings.(stagename)(obj.aap.tasklist.main.module(k).index).ATTRIBUTE.specialrequirements};
            catch
                specialrequirements={};
            end
            if exist('highmem','var') % djm: so can try with highmem after 1st crash, even if not set
                specialrequirements.highmemory=[];
                specialrequirements.unlimit=[];
            end
            
            [obj.aap, workerid]=aas_getboredworker(obj.aap,specialrequirements);
            
            couldbeallocated=false;
            if (~isempty(workerid))
                task=obj.getjobdescription(i);
                if (~isfield(aaparallel.workerstatus.(sprintf('worker%d',workerid)),'allocatedjobs'))
                    aaparallel.workerstatus.(sprintf('worker%d',workerid)).allocatedjobs={task};
                else
                    aaparallel.workerstatus.(sprintf('worker%d',workerid)).allocatedjobs=[aaparallel.workerstatus.(sprintf('worker%d',workerid)).allocatedjobs,{task}];
                end
                couldbeallocated=true;
            end
        end
        
        % =================================
        function jobTable = jobqueue2table(obj)
            % Create table from ob.jobqueue and a few other variables 
            % for inspection/debugging purposes
            numJob = numel(obj.jobqueue);
            jobTable = struct2table(obj.jobqueue, 'AsArray', true);
            % preallocate a few informative columns:
            % - order in which jobs are executed (place this column
            %   in first position)
            jobTable.execorder = repmat(-1, [numJob, 1]);
            jobTable = jobTable(:, [end, 1:end-1]);
            % state (of job) and potential errors
            jobTable.state = repmat({''}, [numJob, 1]);
            jobTable.error = repmat({''}, [numJob, 1]);
        end
        
        % =================================
        function [obj,task]=getjobdescription(obj,i)
            % Get job description
            k=obj.jobqueue(i).k;
            clear task;
            task.name='doprocessing';
            task.aap=obj.aap;
            task.taskqueueposition=i;
            task.aap.tasklist.currenttask.epiprefix=obj.aap.tasklist.main.module(k).epiprefix;
            task.aap.tasklist.currenttask.extraparameters=obj.aap.tasklist.main.module(k).extraparameters;
            task.aap.internal.jobqueue=obj.jobqueue(i);
            task.aap.tasklist.currenttask.name=obj.aap.tasklist.main.module(k).name;
            task.aap.tasklist.currenttask.index=obj.aap.tasklist.main.module(k).index;
            % now set output root, which may be tailored for this stage
            task.aap.acq_details.root=obj.jobqueue(i).outputroot;
            task.aap.acq_details.rootsuffix=obj.jobqueue(i).rootsuffix;
        end
        
        % =================================
        % The default, Mono threaded...
        function [obj]=runall(obj,dontcloseexistingworkers,waitforalljobs)
            % Run all tasks on the queue, single threaded
            global aaparallel
            
            njobs=length(obj.jobqueue);
            for i=1:njobs
                job=obj.jobqueue(i);
                obj.aap.acq_details.root=job.outputroot;
                obj.aap.acq_details.rootsuffix=job.rootsuffix;
                obj.aap.acq_details.inputrootsuffix=job.inputrootsuffix;
                
                aa_doprocessing_onetask(obj.aap,job.task,job.k);
            end
            obj.emptyqueue;
        end
       
    end
    
    % Utils
    methods (Hidden, Access = protected)
        function argout = SetArg(obj,argin,key,value)
            argout = argin;
            if ~iscell(argout), argout = {argout}; end
            ind = find(cellfun(@(x) strcmp(x,key),argout));
            if ind, argout(ind:ind+1) = []; end
            argout(end+1:end+2) = {key value};
        end
    end
end
