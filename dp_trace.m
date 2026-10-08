function [cs, rs, info] = dp_trace(I, fr, guide, opt)
%DP_TRACE  二阶（曲率惩罚）全局最优路径提取
%   代价 = Σ 墨水代价 + λ1·Σ|斜率| + λ2·Σ|曲率|，状态=(行偏移,斜率)，全局 Viterbi。
%   与逐列贪心的区别：整条曲线一次求全局最优，不会因单列误判而累积漂移。
%   关键约束：① 只允许在引导线 ±band 内；② 框线±6px 内一律禁入（否则会被更黑的框吸走）；
%             ③ 墨水代价按"本曲线自身颜色"的混色模型算（不是单纯亮度），干扰更小。
%   opt: band(30) maxStep(6) lam1(0.04) lam2(0.06) iter(2) core([])
if nargin < 4, opt = struct(); end
gf = @(f,d) getfld(opt,f,d);
B = gf('band',22); M = gf('maxStep',8);
lam1 = gf('lam1',0.02); lam2 = gf('lam2',0.03); iter = gf('iter',2);
wg = gf('wguide',0.20);   % 软引导（封顶线性）：
                          %   近处斜率大 -> 挡住跳到只隔几 px 的平行邻线；
                          %   远处封顶     -> 仍允许纠正引导线本身的大偏差
core = gf('core',[]);
loB = gf('lo',[]); hiB = gf('hi',[]);   % 逐列绝对行硬带（非交叉约束）
I = double(I); [H,W,~] = size(I);
g = mean(I,3)/255; ch = (max(I,[],3)-min(I,[],3))/255;
rTop = max(1, round(fr(1)) + 6); rBot = min(H, round(fr(2)) - 6);
cLft = max(1, round(fr(3)) + 2); cRgt = min(W, round(fr(4)) - 2);
if ~isempty(core)
   u = 255 - reshape(core,1,3); n2 = u*u';
   if n2 < 1e3, core = []; end
end
cs = []; rs = []; info = struct('cost',NaN);
for it = 1:max(1,iter)
   gd = guide; gd(gd < rTop) = rTop; gd(gd > rBot) = rBot;
   if ~isempty(loB)
      loB = max(loB, rTop); hiB = min(hiB, rBot);
      fin = isfinite(gd);
      gd(fin) = min(max(gd(fin), loB(fin)), hiB(fin));   % 只钳位有效值（NaN 必须保留，
   end                                                    %  否则 cA/cB 会退化成整幅宽度）
   rr0 = round(gd);
   fin2 = isfinite(rr0);
   rr0(fin2) = min(max(rr0(fin2), rTop), rBot);
   cA = max(cLft, find(~isnan(gd),1)); cB = min(cRgt, find(~isnan(gd),1,'last'));
   if isempty(cA) || cB - cA < 20, return; end
   if ~isempty(loB)
      B = max(6, min(60, ceil(max(hiB - loB)/2) + 3));
   end
   B = max(6, min(B, 60));
   NO = 2*B+1; NS = 2*M+1;
   off = (-B:B)';
   Dc = inf(NO, W);
   for c = cA:cB
      rr = min(max(rr0(c)+off, rTop), rBot);
      if isempty(core)
         Dc(:,c) = 1 - max(1-g(sub2ind([H W], rr, repmat(c,NO,1))), ...
                            ch(sub2ind([H W], rr, repmat(c,NO,1))));
      else
         P = reshape(I(rr, c, :), NO, 3);
         al = min(max(((255-P)*u')/n2, 0), 1);
         rz = sqrt(sum((255-P-al*u).^2, 2));
         Dc(:,c) = 1 - al .* exp(-(rz/40).^2);
      end
      Dc(:,c) = Dc(:,c) + wg * min(abs(off), 6);   % 封顶线性软引导
      if ~isempty(loB), Dc(rr < loB(c) | rr > hiB(c), c) = 1e3; end   % 非交叉硬带
      Dc(rr <= rTop | rr >= rBot, c) = 1e3;      % 贴框禁入
   end
   nC = cB - cA + 1;
   bp = zeros(NO, NS, nC, 'int16');   % int8 在 NS>127 时会溢出（maxStep>63）
   Cprev = repmat(Dc(:,cA), 1, NS);
   for c = cA+1 : cB
      dg = rr0(c) - rr0(c-1);
      Cn = inf(NO, NS);
      for si = 1:NS
         sp = si - (M+1);
         op = (1:NO)' + dg - sp;
         ok = op >= 1 & op <= NO;
         if ~any(ok), continue; end
         opc = min(max(op,1),NO);
         bestv = inf(NO,1); bests = ones(NO,1);
         for sj = 1:NS
            sprev = sj - (M+1);
            v = Cprev(opc + (sj-1)*NO) ...        % 线性索引，比 sub2ind 快数倍
                + lam1*abs(sp) + lam2*abs(sp - sprev);
            uu = v < bestv; bestv(uu) = v(uu); bests(uu) = sj;
         end
         bestv(~ok) = inf;
         Cn(:,si) = bestv + Dc(:,c);
         bp(:,si,c-cA+1) = int8(bests);
      end
      Cprev = Cn;
   end
   [~, li] = min(Cprev(:));
   [oi, si] = ind2sub([NO NS], li);
   cs = zeros(nC,1); rs = zeros(nC,1);
   for q = nC:-1:1
      c = cA + q - 1;
      cs(q) = c; rs(q) = min(max(rr0(c) + (oi - (B+1)), rTop), rBot);
      if q > 1
         dg = rr0(c) - rr0(c-1);
         sp = si - (M+1);
         siPrev = double(bp(oi, si, q));
         oi = oi + dg - sp; si = siPrev;
         oi = min(max(oi,1),NO); si = min(max(si,1),NS);
      end
   end
   inkv = max(1-g, ch);
   rs2 = rs;
   for q = 1:nC
      c = cs(q); r0 = round(rs(q)); lo = max(1,r0-3); hi = min(H,r0+3);
      w = max(0, inkv(lo:hi,c) - 0.12);
      if sum(w) > 0, rs2(q) = sum((lo:hi)'.*w)/sum(w); end
   end
   rs = rs2;
   guide = nan(1,W); guide(cs) = rs;
   B = max(6, round(B/2));   % 不要再抬到 12：窄带曲线会被放宽而串线
   info.cost = min(Cprev(:));
end
end
function v = getfld(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end
