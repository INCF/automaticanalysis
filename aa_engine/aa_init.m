% Automatic analysis - initialise paths from recipe

function [aap]=aa_init(aap)

global aa

% detect running aa
if isobject(aa)
    aas_log(aap,false,'WARNING: Previous execution of aa was not closed! Killing jobs...\n')
    aas_log(aap,false,'WARNING: The path settings for both linux and MATLAB may have been modified! You may need to revise them.')
    aas_log(aap,false,'WARNING: Please, make sure that you use aa_close(aap) next time before you start a new analysis!')
    aa_close(aap,'restorewarnings','killjobs');
    aas_log(aap,false,'\nWARNING: Done!')
else
    aa = aaClass('nopath','nogreet');
end

% cleanup aaworker path
if isfield(aap.options,'aaworkercleanup') && ~isempty(aap.options.aaworkercleanup)
    aawp = aaworker_getparmpath(aap);
    for d = dir(fullfile(aawp,'aaworker*'))'
        if etime(clock,datevec(d.datenum))/(24*60*60) > aap.options.aaworkercleanup
            aas_log(aap,false,sprintf('INFO: aaworker folder %s is older than %d days...Deleting',d.name,aap.options.aaworkercleanup))
            try
                rmdir(fullfile(aawp,d.name),'s');
            catch
                aas_log(aap, false, sprintf('WARNING: Could not remove %s. Please remove manually.',fullfile(aawp,d.name)))
                pause(3)
            end
        end
    end
end

% Set UTC time function
if exist('utc_time','file')
    utc_time = @utc_time;
else
    aas_log(aap,false,'INFO: utc_time is not found. java function will be used\n')
    utc_time = @java.lang.System.currentTimeMillis;
end
aas_cache_put(aap,'utc_time',utc_time,'utils');

%% Set Paths
aas_cache_put(aap,'bcp_path',path,'system');
aas_cache_put(aap,'bcp_shellpath',getenv('PATH'),'system');

% Path for SPM
if ~isempty(aap.directory_conventions.spmdir)
    % by setting this environment variable it becomes possible to define other
    % paths relative to $SPMDIR in defaults files and task lists
    setenv('SPMDIR',aap.directory_conventions.spmdir);
end

if isdeployed
    aap.directory_conventions.spmdir = spm('Dir');
    setenv('SPMDIR',aap.directory_conventions.spmdir);
end

% expand shell paths (before SPM so SPM can be in e.g. home directory)
aap = aas_expandpathbyvars(aap, aap.options.verbose>2);

if isempty(aap.directory_conventions.spmdir)
    if isempty(which('spm'))
        aas_log(aap,true,'You''re going to need SPM, add it to your paths manually or set aap.directory_conventions.spmdir');
    else
        aap.directory_conventions.spmdir=spm('Dir');
    end;
end;

if isfield(aap, 'spm') && isfield(aap.spm, 'defaults')
    oldspmdefaults = aap.spm.defaults;
end

addpath(aap.directory_conventions.spmdir);
spm_jobman('initcfg');

try
    aap.spm.defaults=spm_get_defaults;
catch
    global defaults    
    if isstruct(defaults)
        aas_log(aap,false,'WARNING: SPM defaults has not been found, global defaults will be used');
        aap.spm.defaults=defaults;
    else
        aap.spm.defaults = struct;
    end
end

if exist('oldspmdefaults', 'var')
    aap.spm.defaults = setstructfields(aap.spm.defaults, oldspmdefaults);
end
aap.aap_beforeuserchanges.spm.defaults = aap.spm.defaults;

% Path for SPM MEG/EEG
addpath(fullfile(spm('Dir'),'external','fieldtrip'));
clear ft_defaults
clear global ft_default
ft_defaults;
global ft_default
ft_default.trackcallinfo = 'no';
ft_default.showcallinfo = 'no';
addpath(...
    fullfile(spm('Dir'),'external','bemcp'),...
    fullfile(spm('Dir'),'external','ctf'),...
    fullfile(spm('Dir'),'external','eeprobe'),...
    fullfile(spm('Dir'),'external','mne'),...
    fullfile(spm('Dir'),'external','yokogawa_meg_reader'),...
    fullfile(spm('Dir'),'toolbox', 'dcm_meeg'),...
    fullfile(spm('Dir'),'toolbox', 'spectral'),...
    fullfile(spm('Dir'),'toolbox', 'Neural_Models'),...
    fullfile(spm('Dir'),'toolbox', 'MEEGtools'));

% Path fore spmtools
if isfield(aap.directory_conventions,'spmtoolsdir') && ~isempty(aap.directory_conventions.spmtoolsdir)
    SPMTools = textscan(aap.directory_conventions.spmtoolsdir,'%s','delimiter', ':'); SPMTools = SPMTools{1};
    for pp = SPMTools'
        addpath(pp{1});
    end
end

% Path for EEGLAB, if specified
if ~isempty(aap.directory_conventions.eeglabdir)
    addpath(...
        fullfile(aap.directory_conventions.eeglabdir,'functions'),...
        fullfile(aap.directory_conventions.eeglabdir,'functions', 'adminfunc'),...
        fullfile(aap.directory_conventions.eeglabdir,'functions', 'sigprocfunc'),...
        fullfile(aap.directory_conventions.eeglabdir,'functions', 'guifunc'),...
        fullfile(aap.directory_conventions.eeglabdir,'functions', 'studyfunc'),...
        fullfile(aap.directory_conventions.eeglabdir,'functions', 'popfunc'),...
        fullfile(aap.directory_conventions.eeglabdir,'functions', 'statistics'),...
        fullfile(aap.directory_conventions.eeglabdir,'functions', 'timefreqfunc'),...
        fullfile(aap.directory_conventions.eeglabdir,'functions', 'miscfunc'),...
        fullfile(aap.directory_conventions.eeglabdir,'functions', 'resources'),...
        fullfile(aap.directory_conventions.eeglabdir,'functions', 'javachatfunc')...
        );
else
    % Check whether already in path, give warning if not
    if isempty(which('eeglab'))
       aas_log(aap,false,sprintf('EEG lab not found, if you need this you should add it to the matlab path manually, or set aap.directory_conventions.eeglabdir'));
    end;
end;

% Path to GIFT
if ~isempty(aap.directory_conventions.GIFTdir)
    addpath(genpath(aap.directory_conventions.GIFTdir));
else
    % Check whether already in path, give warning if not
    if isempty(which('icatb_runAnalysis'))
       aas_log(aap,false,sprintf('GIFT not found, if you need this you should add it to the matlab path manually, or set aap.directory_conventions.GIFTdir'));
    end;
end;

% Path to BrainWavelet
if ~isempty(aap.directory_conventions.BrainWaveletdir)
    addpath(fullfile(aap.directory_conventions.BrainWaveletdir,'BWT'));
    addpath(fullfile(aap.directory_conventions.BrainWaveletdir,'third_party','cprintf'));
    addpath(fullfile(aap.directory_conventions.BrainWaveletdir,'third_party','NIfTI'));
    addpath(fullfile(aap.directory_conventions.BrainWaveletdir,'third_party','wmtsa','dwt'));
    addpath(fullfile(aap.directory_conventions.BrainWaveletdir,'third_party','wmtsa','utils'));
else
    % Check whether already in path, give warning if not
    if isempty(which('WaveletDespike'))
       aas_log(aap,false,sprintf('BrainWavelet not found, if you need this you should add it to the matlab path manually, or set aap.directory_conventions.BrainWaveletdir'));
    end;
end

% Path to FaceMasking
if isfield(aap.directory_conventions,'FaceMaskingdir') && ~isempty(aap.directory_conventions.FaceMaskingdir)
    addpath(genpath(fullfile(aap.directory_conventions.FaceMaskingdir,'matlab')));
else
    % Check whether already in path, give warning if not
    if isempty(which('mask_surf_auto'))
       aas_log(aap,false,sprintf('FaceMasking not found, if you need this you should add it to the matlab path manually, or set aap.directory_conventions.FaceMaskingdir'));
    end;
end;

% Path to LI toolbox
if isfield(aap.directory_conventions,'LIdir') && ~isempty(aap.directory_conventions.LIdir)
    addpath(aap.directory_conventions.LIdir);
else
    % Check whether already in path, give warning if not
    if isempty(which('LI'))
       aas_log(aap,false,sprintf('LI toolbox not found, if you need this you should add it to the matlab path manually, or set aap.directory_conventions.LIdir'));
    end;
end;


% Path to DCMTK
if isfield(aap.directory_conventions,'DCMTKdir') && ~isempty(aap.directory_conventions.DCMTKdir)
    [s,p] = aas_cache_get(aap,'bcp_shellpath','system');
    setenv('PATH',[p ':' fullfile(aap.directory_conventions.DCMTKdir,'bin')]);
end



% Path to spm modifications to the top
addpath(fullfile(aa.Path,'extrafunctions','spm_mods'),'-begin');

%% Build required path list for cluster submission
% aa
reqpath=textscan(genpath(aa.Path),'%s','delimiter',':'); reqpath = reqpath{1};

p = textscan(path,'%s','delimiter',':'); p = p{1};

% spm
p_ind = cell_index(p,aap.directory_conventions.spmdir); % SPM-related dir
for ip = p_ind
    reqpath{end+1} = p{ip};
end
% spmtools
if isfield(aap.directory_conventions,'spmtoolsdir') && ~isempty(aap.directory_conventions.spmtoolsdir)
    SPMTools = textscan(aap.directory_conventions.spmtoolsdir,'%s','delimiter', ':'); SPMTools = SPMTools{1};
    for pp = SPMTools'
        if exist(pp{1},'dir')
            pdir = textscan(genpath(pp{1}),'%s','delimiter', ':'); pdir = pdir{1};
            reqpath = [reqpath; pdir];
        end
    end
end

% MNE
if isfield(aap.directory_conventions,'mnedir') && ~isempty(aap.directory_conventions.mnedir)
    if exist(fullfile(aap.directory_conventions.mnedir,'matlab'),'dir')
        reqpath{end+1}=fullfile(aap.directory_conventions.mnedir,'matlab','toolbox');
        reqpath{end+1}=fullfile(aap.directory_conventions.mnedir,'matlab','examples');
    end
end

% EEGLAB
if ~isempty(aap.directory_conventions.eeglabdir)
    p_ind = cell_index(p,aap.directory_conventions.eeglabdir);
    for ip = p_ind
        reqpath{end+1} = p{ip};
    end
end;

% GIFT
if ~isempty(aap.directory_conventions.GIFTdir)
    p_ind = cell_index(p,aap.directory_conventions.GIFTdir);
    for ip = p_ind
        reqpath{end+1} = p{ip};
    end
end

% BrainWavelet
if ~isempty(aap.directory_conventions.BrainWaveletdir)
    p_ind = cell_index(p,aap.directory_conventions.BrainWaveletdir);
    for ip = p_ind
        reqpath{end+1} = p{ip};
    end
end

% FaceMasking
if isfield(aap.directory_conventions,'FaceMaskingdir') && ~isempty(aap.directory_conventions.FaceMaskingdir)
    p_ind = cell_index(p,aap.directory_conventions.FaceMaskingdir);
    for ip = p_ind
        reqpath{end+1} = p{ip};
    end
end

% LI
if isfield(aap.directory_conventions,'LIdir') && ~isempty(aap.directory_conventions.LIdir)
    p_ind = cell_index(p,aap.directory_conventions.LIdir);
    for ip = p_ind
        reqpath{end+1} = p{ip};
    end
end

% clean
reqpath=reqpath(strcmp('',reqpath)==0);
exc = cell_index(reqpath,'.git');
if exc, reqpath(exc) = []; end

aas_cache_put(aap,'reqpath',reqpath,'system');
% switch off warnings
warnings(1) = warning('off','MATLAB:Completion:CorrespondingMCodeIsEmpty');
warnings(2) = warning('off','MATLAB:getframe:RequestedRectangleExceedsFigureBounds');
aas_cache_put(aap,'warnings',warnings,'system');
