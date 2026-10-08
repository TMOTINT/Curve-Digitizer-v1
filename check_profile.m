
function check_profile()
%CHECK_PROFILE  合并带的严格判据：把"提取出的各条曲线"按实测笔画剖面叠加成预测剖面，
%               再与图像里真实的墨迹剖面比形状（都归一化到峰值 1，L1 失配）。
%   · 这是唯一能评价"多根线挤在一起"的客观判据 —— 那时单列剖面上只有一两个墨峰，
%     "谁在哪"必须靠整个剖面的形状去约束。
%   · 关键是对照组：把曲线整体平移 ±1 / ±2 px，看失配是否变差。
%     若平移后明显变差，说明判据有分辨力；若当前失配已与平移 1px 相当，说明到了极限。
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2();
for i = 1:numel(S)
   tag = S(i).tag;
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I=repmat(I,1,1,3); end
   L = load(fullfile('digitized_final',[tag '.mat'])); CR = L.CR;
   d0 = double(I); g = mean(d0,3)/255; ch = (max(d0,[],3)-min(d0,[],3))/255;
   V = max(1-g, ch); [H,W] = size(V);
   fr = S(i).frame;
   rT = max(1,round(fr(1))+6); rB = min(H,round(fr(2))-6);
   cL = max(1,round(fr(3))+6); cR = min(W,round(fr(4))-6);
   % ---- 实测单笔画剖面模板 ----
   [ink, wLine] = ink_for_figure(I, fr, tag);
   Tw = 14; Ss = (-Tw:0.5:Tw)'; acc = zeros(numel(Ss),1); cnt = 0;
   for c = cL:20:cR
      rr = find(ink(:,c)); if isempty(rr), continue; end
      bk=[0;find(diff(rr)>2);numel(rr)];
      for t=1:numel(bk)-1
         gr=rr(bk(t)+1:bk(t+1));
         if numel(gr) < 0.7*2*wLine || numel(gr) > 1.5*2*wLine, continue; end
         r0 = mean(gr);
         Y = r0 + Ss; if min(Y)<1 || max(Y)>H, continue; end
         v = interp2(V, repmat(c,numel(Ss),1), Y, 'linear', 0);
         if max(v) <= 0.2, continue; end
         acc = acc + v/max(v); cnt = cnt + 1;
      end
   end
   if cnt < 20, fprintf('%-6s 模板样本不足(%d)\n', tag, cnt); continue; end
   T = acc/cnt;
   % ---- 逐列预测 vs 实测 ----
   Yk = cell(1,numel(CR));
   for k=1:numel(CR)
      Yk{k} = interp1(CR(k).px, CR(k).py, (1:W), 'linear', NaN);
   end
   mm = zeros(1,W); dense = false(1,W); ndense = 0;
   for c = cL:cR
      obs = V(rT:rB, c);
      if max(obs) <= 0.15, continue; end
      mw = zeros(rB-rT+1,1); nIn = 0; lo = inf; hi = -inf;
      for k=1:numel(CR)
         y = Yk{k}(c); if ~isfinite(y), continue; end
         nIn = nIn + 1;
         d = (rT:rB)' - y;
         mw = mw + interp1(Ss, T, d, 'linear', 0);
         lo = min(lo, y); hi = max(hi, y);
      end
      if nIn == 0, continue; end
      pred = mw;
      pred = pred/max(pred); obsN = obs/max(obs);
      mm(c) = mean(abs(obsN - pred));
      if (hi-lo) < 4*wLine, dense(c) = true; ndense = ndense+1; end
   end
   ok = mm > 0;
   fprintf('%-6s 全幅失配中位=%.4f | 合并带列数=%4d 失配中位=%.4f\n', tag, median(mm(ok)), ndense, median(mm(dense & ok)));
   % ---- 对照组：整体平移 ----
   for sh = [1 2]
      mm2 = zeros(1,W);
      for c = cL:cR
         obs = V(rT:rB, c); if max(obs) <= 0.15, continue; end
         mw = zeros(rB-rT+1,1); nIn=0;
         for k=1:numel(CR)
            y = Yk{k}(c); if ~isfinite(y), continue; end
            nIn=nIn+1; d = (rT:rB)' - (y+sh);
            mw = mw + interp1(Ss, T, d, 'linear', 0);
         end
         if nIn==0, continue; end
         pred = mw/max(mw); obsN = obs/max(obs);
         mm2(c) = mean(abs(obsN - pred));
      end
      o2 = mm2>0;
      fprintf('        平移 +%dpx: 全幅中位=%.4f 合并带中位=%.4f\n', sh, median(mm2(o2)), median(mm2(dense&o2)));
   end
end
end
