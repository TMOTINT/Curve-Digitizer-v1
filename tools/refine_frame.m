function ax2 = refine_frame(I, ax, opt)
%REFINE_FRAME  把自动检出的轴框微调到"轴脊中心"（亚像素）
%
%   动机：detectAxes 用阈值化的暗带均值定位轴脊。抗锯齿边缘、外框线、
%         刻度根部会让暗带偏向一侧，实测偏 1~6 px（fig3D 偏 5.5 px）。
%         轴框一旦偏移，整条曲线的数据坐标就会整体平移（fig3A 偏 50 nm）。
%
%   做法：以检出位置为中心取 ±band 的"行/列暗度剖面"，
%         用半高全宽范围内的暗度加权质心求中心 —— 半高法天然对称，
%         不受一侧淡出/一侧硬边的不对称影响；迭代两次收敛到亚像素。
%
%   安全性（任何一步不满足就原样返回，绝不把变差的框交出去）：
%     ① 剖面无效/无峰 -> 原值
%     ② 微调幅度 > maxShift -> 视为不可信，原值
%     ③ 微调后框面积不足原框 60% -> 原值
if nargin < 3, opt = struct(); end
gf = @(f,d) getf(s,f,d);
band = gf('band',14); maxShift = gf('maxShift',10); iters = gf('iters',2);
D = double(I);
if size(D,3) == 3, g = mean(D,3)/255; else, g = D/255; end
ink = max(0, 1 - g);                      % 暗度剖面
[H,W] = size(ink);
ax2 = ax;
for it = 1:max(1,iters)
   rT = snapRow(ink, ax2.rowTop,    band, maxShift, H);
   rB = snapRow(ink, ax2.rowBottom, band, maxShift, H);
   cL = snapCol(ink, ax2.colLeft,   band, maxShift, W);
   cR = snapCol(ink, ax2.colRight,  band, maxShift, W);
   if ~(rT < rB && cL < cR), return; end
   % ③ 面积不得大幅缩水
   if (rB-rT) < 0.6*(ax.rowBottom-ax.rowTop) || (cR-cL) < 0.6*(ax.colRight-ax.colLeft), return; end
   ax2 = struct('rowTop', rT, 'rowBottom', rB, 'colLeft', cL, 'colRight', cR);
end
end

function r2 = snapRow(ink, r, band, maxShift, H)
r2 = r;
a = max(1, round(r)-band); b = min(H, round(r)+band);
if b - a < 3, return; end
p = mean(ink(a:b, :), 2);
c = cenHalfMax(p);
if isfinite(c), q = a + c - 1; if abs(q - r) <= maxShift, r2 = q; end; end
end

function c2 = snapCol(ink, c, band, maxShift, W)
c2 = c;
a = max(1, round(c)-band); b = min(W, round(c)+band);
if b - a < 3, return; end
p = mean(ink(:, a:b), 1)';
cc = cenHalfMax(p);
if isfinite(cc), q = a + cc - 1; if abs(q - c) <= maxShift, c2 = q; end; end
end

function c = cenHalfMax(p)
%CENHALFMAX  取峰两侧降到半高处的范围内做加权质心（亚像素、抗不对称）
c = NaN;
if numel(p) < 3, return; end
[pk, j] = max(p);
if ~isfinite(pk) || pk <= 0, return; end
lo = j; while lo > 1 && p(lo-1) >= 0.5*pk, lo = lo - 1; end
hi = j; while hi < numel(p) && p(hi+1) >= 0.5*pk, hi = hi + 1; end
w = p(lo:hi) - 0.5*pk; w(w < 0) = 0;
if sum(w) <= 0, return; end
c = sum(((lo:hi)').*w) / sum(w);
end

function v = getf(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end
