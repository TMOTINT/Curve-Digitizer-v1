
function check_bias2()
%CHECK_BIAS2  更严格的逐列偏差：只认"包含该曲线的那一段墨迹"，并画偏差-列曲线图
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2();
figs = {'fig3D','fig3C'};
for ff = 1:numel(figs)
   tag = figs{ff};
   i = find(strcmp({S.tag}, tag));
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I=repmat(I,1,1,3); end
   L = load(fullfile('digitized_final',[tag '.mat'])); CR = L.CR;
   [ink, wLine] = ink_for_figure(I, S(i).frame, tag);
   d0 = double(I); g = mean(d0,3)/255; ch = (max(d0,[],3)-min(d0,[],3))/255;
   V = max(1-g, ch); [H,~] = size(ink);
   f = figure('Visible','off','Color','w','Position',[40 40 1400 160*numel(CR)]);
   fprintf('=== %s (半宽 %.1f) ===\n', tag, wLine);
   for k = 1:numel(CR)
      cs = CR(k).px(:); rs = CR(k).py(:); d = nan(size(rs));
      for q = 1:numel(cs)
         c = cs(q); if c<1||c>size(ink,2), continue; end
         rr = find(ink(:,c)); if isempty(rr), continue; end
         bk = [0;find(diff(rr)>2);numel(rr)]; best = [];
         for t = 1:numel(bk)-1
            gr = rr(bk(t)+1:bk(t+1));
            if rs(q) >= gr(1)-2 && rs(q) <= gr(end)+2, best = gr; break; end
         end
         if isempty(best), continue; end
         a = max(1,best(1)-2); b = min(H,best(end)+2);
         wgt = V(a:b,c); if sum(wgt)<=1e-6, continue; end
         d(q) = rs(q) - sum((a:b)'.*wgt)/sum(wgt);
      end
      ok = isfinite(d); dd = d(ok);
      fprintf('  c%-2d 中位%6.2f p90%6.2f 最大%6.2f  超1px %4d/%4d\n', k, ...
         median(abs(dd)), prctile(abs(dd),90), max(abs(dd)), sum(abs(dd)>1), numel(dd));
      subplot(numel(CR),1,k); plot(cs(ok), d(ok), 'b-'); ylim([-15 15]); grid on;
      ylabel(sprintf('c%d',k)); title(sprintf('%s c%d 偏差(曲线行 - 墨心行)', tag, k));
      if k==numel(CR), xlabel('列'); end
   end
   print(f,'-dpng','-r80', fullfile('qa',['bias_' tag '.png'])); close(f);
end
end
