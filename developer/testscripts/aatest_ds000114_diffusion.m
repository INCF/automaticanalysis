function aatest_ds000114_diffusion(deleteprevious,wheretoprocess)
% developer PR test script
%
% description: BIDS multimodal dataset ds000114 -- diffusion
%

% -------------------------------------------------------------------------
% init
% -------------------------------------------------------------------------

aap = aa_test_inittest(mfilename('fullpath'),deleteprevious);

% -------------------------------------------------------------------------
% analysis options
% -------------------------------------------------------------------------

aap.options.wheretoprocess = wheretoprocess;

aap.acq_details.numdummies = 1;
aap.acq_details.input.combinemultiple = 1;
aap.options.autoidentifystructural_choosefirst = 1;

aap.tasksettings.aamod_diffusion_bet.bet_f_parameter = 0.4;

% -------------------------------------------------------------------------
% BIDS
% -------------------------------------------------------------------------
aap.acq_details.input.selected_subjects = {'sub-01'};

aap = aas_processBIDS(aap);

% -------------------------------------------------------------------------
% run
% -------------------------------------------------------------------------

aa_doprocessing(aap);

% if directory_conventions.reportname is undefined, skip reporting

if isfield(aap.directory_conventions,'reportname') && ~isempty(aap.directory_conventions.reportname)
    aa_report(fullfile(aas_getstudypath(aap),aap.directory_conventions.analysisid));
end


aa_close(aap);

