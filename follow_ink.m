function [cs, rs] = follow_ink(I, fr, gd, core, opt)
%FOLLOW_INK  逐列"照原样"跟随本曲线颜色的墨（零平滑）
%   v2 三项修复：
%     ① 步长自适应：step = max(base, 2.2*|上次斜率| + 14)，陡段自动放宽
%     ② 断点重捕获：跟丢时先用引导线重锚、再放大窗口重试，都失败才算 miss
%     ③ 起始锁定：起步用 ±80 大窗搜索，避免一开始就锚错
%   返回逐列 [列, 行]；调用方负责覆盖检查（覆盖不足就退回 DP）
if nargin < 5, opt = struct(); end
gf = @(f,d) getfld(opt,f,d);
baseStep = gf('step', 28); missMax = gf('missMax', 60); wide = gf('wide', 2.4);
H = size(I,1); u = 255 - reshape(core,1,3); n2 = u*u';
rTop = max(2, round(fr(1))+2); rBot = min(H, round(fr(2))-2);
cA = find(~isnan(gd), 1); cB = find(~isnan(gd), 1, 'last');
cs = []; rs = [];
if isempty(cA), return; end

   function r2 = probe(c, rPred, win)
      % 在 c 列、预测行 rPred 的 ±win 内找本曲线颜色的墨，返回段中点；找不到返回 NaN
      a = max(rTop, round(rPred)-win); b = min(rBot, round(rPred)+win);
      P = reshape(double(I(a:b, c, :)), [], 3);
      if n2 >= 1e3
         al = min(max(((255-P)*u')/n2, 0), 1);
         rz = sqrt(sum((255-P-al*u).^2, 2));
         q = al .* exp(-(rz/40).^2);
      else
         q = max(0, 1 - mean(P,2)/255 - 0.12);
      end
      on = q > 0.35;
      r2 = NaN;
      if ~any(on), return; end
      idx = find(on); rp = round(rPred) - a + 1;
      [~, j0] = min(abs(idx - rp));
      p1 = idx(j0); p2 = p1;
      while p1 > 1 && on(p1-1), p1 = p1 - 1; end
      while p2 < numel(on) && on(p2+1), p2 = p2 + 1; end
      r2 = a + (p1 + p2)/2 - 1;
   end

for dir = [1 -1]
   if dir > 0, c = cA; else, c = cB; end
   r = gd(c); sl = 0; miss = 0;
   r0 = probe(c, r, 80);                    % ① 起始锁定
   if ~isnan(r0), r = r0; end
   while c >= cA && c <= cB
      win = max(baseStep, round(2.2*abs(sl)) + 14);
      rNew = probe(c, r, win);
      if isnan(rNew) && isfinite(gd(c))     % ② 用引导线重锚
         rNew = probe(c, gd(c), win*wide);
      end
      if isnan(rNew) && isfinite(gd(c))     % ② 再放大窗口试一次
         rNew = probe(c, gd(c), 90);
      end
      if ~isnan(rNew)
         sl = 0.6*sl + 0.4*(rNew - r);
         r = rNew; miss = 0;
         cs(end+1,1) = c; rs(end+1,1) = r; %#ok<AGROW>
      else
         miss = miss + 1;
         if isfinite(gd(c)), r = gd(c); else, r = min(rBot, max(rTop, r + sl)); end
         if miss > missMax, break; end
      end
      c = c + dir;
   end
end
if isempty(cs), return; end
[cs, ia] = unique(cs); rs = rs(ia);
end
function v = getfld(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end
