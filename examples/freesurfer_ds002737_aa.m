% Automatic analysis
% User master script example (aa version 5.*.*)
%
% This is an example how to procesprocesss a BIDS multimodal NIfTI dataset. We assume that you
% have already downloaded the dataset to your directory.
%
% Tibor Auer, MRC-CBSU
% 08-02-2016

%% INITIALISE
clear
aa_ver5

%% LOAD TASKLIST
aap = aarecipe('freesurfer_ds002737_tasklist.xml');

% Modify standard recipe module selection here if you'd like
aap.options.wheretoprocess = 'localsingle'; % queuing system			% typical value batch | localsingle


%% STUDY
% Directory for analysed data
aap.acq_details.root = fullfile(aap.acq_details.root,'aa_demo');
aap.directory_conventions.analysisid = 'freesurfer';

% Add data
rawdir = 'ds002737';
sources = strsplit(aap.directory_conventions.rawdatadir,':')';
demoind = cell_index(sources,'aa_demo');
aap.directory_conventions.rawdatadir = fullfile(sources{demoind},rawdir);

aap.acq_details.input.combinemultiple = 1;%aaclose
aap.options.autoidentifystructural_choosefirst = 1;
aap = aas_processBIDS(aap,[],[],{'sub-01'});

%% DO ANALYSIS
aa_doprocessing(aap);
aa_report(fullfile(aas_getstudypath(aap),aap.directory_conventions.analysisid));
