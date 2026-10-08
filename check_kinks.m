
function check_kinks()
%CHECK_KINKS  逐条曲线找"折角"：二阶差分超阈值 = 跳线/粘连留下的折角
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2();
for tag = {'fig3D','fig3A','fig3B','fig3C','fig3E','fig2E'}
   i = find(strcmp({S.tag}, tag{1}));
   L = load(fullfile('digitized_final',[tag{1} '.mat'])); CR = L.CR;
   w = max(2, round(S(i).frame(2)-S(i).frame(1))/1000);
   fprintf('=== %s ===\n', tag{1});
   for k = 1:numel(CR)
      py = CR(k).py(:);
      d2 = abs(diff(py,2));
      nk = sum(d2 > 1.0);
      fprintf('  c%-2d 二阶差分 p50=%5.3f p90=%5.3f p99=%5.3f max=%6.2f   折角(>1px)=%4d/%4d\n', ...
         k, median(d2), prctile(d2,90), prctile(d2,99), max(d2), nk, numel(d2));
   end
end
end
