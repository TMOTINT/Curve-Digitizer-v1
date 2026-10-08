
function audit_curves()
%AUDIT_CURVES  逐条曲线做"失真体检"
%   ① 抖动    与 51 列中位平滑的偏差（90 分位）——路径被局部结构带偏的程度
%   ② 厚度吸附 路径点落在"比线宽更厚的结构"里的比例（fig3B/3C/3E 的圆点、误差棒）
%   ③ 出墨    路径点不在曲线墨迹上的比例
%   ④ 最大跳变 相邻列最大行变化（抄近路/不连续的症状）
%   ⑤ 撞车    两条路径有多少比例的列落在同一根笔画里（同色系区分不好的症状）
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2();
for i = 1:numel(S)
   tag = S(i).tag;
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I=repmat(I,1,1,3); end
   L = load(fullfile('digitized_final',[tag '.mat'])); CR = L.CR;
   [ink, wLine] = ink_for_figure(I, S(i).frame, tag);
   D = bwdist(~ink); [H,W] = size(ink);
   fprintf('=== %s  (笔画半宽 %.1f px) ===\n', tag, wLine);
   P = cell(1,numel(CR));
   for k = 1:numel(CR)
      px = CR(k).px(:); py = CR(k).py(:); P{k} = [px py];
      sm = movmedian(py, 51);
      jit = prctile(abs(py - sm), 90);
      idx = sub2ind([H W], min(max(round(py),1),H), min(max(round(px),1),W));
      fprintf('  c%-2d %-13s n=%4d  抖动%6.2f  厚度吸附%5.1f%%  出墨%5.1f%%  最大跳变%6.1f\n', ...
         k, mat2str(round(CR(k).core)), numel(px), jit, 100*mean(D(idx)>1.5*wLine), ...
         100*mean(~ink(idx)), max(abs(diff(py))));
   end
   for a = 1:numel(P)
      for b = a+1:numel(P)
         [cc,ia,ib] = intersect(P{a}(:,1), P{b}(:,1));
         if numel(cc) < 30, continue; end
         r1 = P{a}(ia,2); r2 = P{b}(ib,2); q = (1:3:numel(cc))'; m = 0;
         for t = 1:numel(q)
            c = cc(q(t));
            lo = max(1,ceil(min(r1(q(t)),r2(q(t))))); hi = min(H,floor(max(r1(q(t)),r2(q(t)))));
            if hi<=lo || all(ink(lo:hi,c)), m = m+1; end
         end
         fr = m/numel(q);
         if fr > 0.30
            fprintf('  !! 路径 %d 与 %d 有 %.1f%% 的列落在同一笔画里\n', a, b, 100*fr);
         end
      end
   end
end
end
