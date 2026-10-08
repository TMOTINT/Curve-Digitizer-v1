
function t_profile()
%T_PROFILE  每条曲线画"原始 py"与"稳健平滑"以及残差，直接暴露抖动/尖刺/台阶
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2();
for i = 1:numel(S)
   tag = S(i).tag;
   L = load(fullfile('digitized_final',[tag '.mat'])); CR = L.CR;
   n = numel(CR);
   f = figure('Visible','off','Color','w','Position',[50 50 1400 220*max(n,1)]);
   for k = 1:n
      px = CR(k).px(:); py = CR(k).py(:);
      sm = movmedian(py, 41);
      r = py - sm;
      subplot(max(n,1),1,k);
      plot(px, py, 'b-', 'LineWidth', 0.8); hold on;
      plot(px, sm, 'r-', 'LineWidth', 0.8);
      grid on; ylabel(sprintf('c%d',k));
      title(sprintf('%s c%d  core=%s   残差 p50=%.2f p90=%.2f max=%.2f px', ...
         tag, k, mat2str(round(CR(k).core)), median(abs(r)), prctile(abs(r),90), max(abs(r))), ...
         'Interpreter','none');
      if k==n, xlabel('列'); end
   end
   print(f, '-dpng', '-r80', fullfile('qa',['profile_' tag '.png'])); close(f);
end
disp('profiles done');
end
