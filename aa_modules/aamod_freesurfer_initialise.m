function [aap,resp]=aamod_freesurfer_initialise(aap,task,subj)

resp='';

switch task
    case 'report'
        
    case 'doit'
    
        % get the images (multichan):
        channels = aas_getstreams(aap,'input');
        if ~iscell(channels)
            channels={channels};
        end
        
		% check for empty streams
		ind = [];
		for c=1:length(channels)
            chaap = aap; chaap.options.verbose = -1;
            if aas_stream_has_contents(chaap,channels{c}) && ~isempty(aas_getfiles_bystream(chaap, subj, channels{c}))
                ind = [ind c];
            end
		end
		channels = channels(ind);
        
		Simg = cell(length(channels));
        for c=1:length(channels)
            Simg{c} = aas_getfiles_bystream(aap, subj, channels{c});

            if isempty(Simg{c}) || strcmp(Simg{c},'/')
                aas_log(aap, true, sprintf('Did not find a %s image.',channels{c}));
            end

            % if more than one found, use the first one and hope this is right
            Simg{c} = strtok(Simg{c}(1,:));
            
            aas_log(aap, false, sprintf('Found %s image: %s\n',channels{c},Simg{c}));
        end
        
        % Set subject paths
        subjname = aap.acq_details.subjects(subj).subjname;
        subjpath = aas_getsubjpath(aap,subj);
        
        setenv('SUBJECTS_DIR', fileparts(subjpath));
        setenv('FREESURFER_DIR', aap.directory_conventions.freesurferdir);
        
        %% initialise fileserver folder structure and nii and mgh files
        aas_freesurfer_init(aap, subjpath, subjname, Simg, 1);
        
        %% Try to delete old freesurfer running flags
        if exist(fullfile(subjpath, 'ANAT', subjname, 'scripts', 'IsRunning.lh+rh'), 'file')
            unix(['rm ' fullfile(subjpath, 'ANAT', subjname, 'scripts', 'IsRunning.lh+rh')]);
        end
        
        %%  make output stream
        % (JC: now specific to FS directories rather than everything under
        % the sun)
        outs = cellfun(@(x) spm_select('FPListRec',fullfile(subjpath,x),'.*'), {'RAW','ANAT','mri'},'UniformOutput',false);
        outs = char(outs(cellfun(@(x) ~isempty(x), outs)));
        aap = aas_desc_outputs(aap,subj,'freesurfer',outs);
        
    case 'checkrequirements'
        if ~aas_cache_get(aap,'spm'), aas_log(aap,true,'SPM is not found'); end
end
