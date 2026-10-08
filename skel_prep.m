function [sk, rowOf, info] = skel_prep(I, fr, opt)
%SKEL_PREP  墨迹掩膜 -> 长连通域 -> 骨架 -> 剪枝；返回骨架与逐列候选行
if nargin < 3, opt = struct(); end
minSpan = getf2(opt,'minSpan',0.50); edgeSkip = getf2(opt,'edgeSkip',8);
maxSpur = getf2(opt,'maxSpur',70);
I = double(I); [H,W,~] = size(I);
top = max(1,round(fr(1))); bot = min(H,round(fr(2)));
lft = max(1,round(fr(3))); rgt = min(W,round(fr(4)));
g = mean(I,3)/255; ch = (max(I,[],3)-min(I,[],3))/255;
inner = false(H,W); inner(top+edgeSkip:bot-edgeSkip, lft+edgeSkip:rgt-edgeSkip) = true;
gi = g(inner); p95 = prctile(gi,95); p02 = prctile(gi,2);
thr = p95 - 0.30*max(0.05, p95-p02);
BW = ((g < thr) | (ch > 0.10)) & inner;
if isfield(opt,'block') && ~isempty(opt.block)
   b = opt.block; BW(max(1,b(1)):min(H,b(2)), max(1,b(3)):min(W,b(4))) = false;
end
% ---- 显式去掉框线：整行/整列几乎全暗 = 轴脊 ----
% 仅靠 edgeSkip 抹不干净（界面自动轴框可能落在轴脊外侧），
% 长横线会被当成长曲线（fig3D 实测把上框当成了曲线）。
if any(BW(:))
   rowFrac = mean(BW(:, lft:rgt), 2);
   for r = find(rowFrac > 0.85)'
      BW(max(1,r-3):min(H,r+3), :) = false;
   end
   colFrac = mean(BW(top:bot, :), 1);
   for c2 = find(colFrac > 0.85)
      BW(:, max(1,c2-3):min(W,c2+3)) = false;
   end
end
BW = imclose(BW, strel('disk',2));
CC = bwlabel(BW, 8);
st = regionprops(CC, 'BoundingBox','Area','PixelIdxList');
BW2 = false(H,W); wmin = minSpan*(rgt-lft); nk = 0;
for k = 1:numel(st)
   if st(k).BoundingBox(3) >= wmin && st(k).Area >= 40
      BW2(st(k).PixelIdxList) = true; nk = nk + 1;
   end
end
sk = bwmorph(BW2, 'skel', Inf);
nSk0 = sum(sk(:));
sk = pruneSpurs(sk, maxSpur, 6);
nSk1 = sum(sk(:));
sk = bwareaopen(sk, 8);
rowOf = cell(1,W);
[rp, cp] = find(sk);
for k = 1:numel(rp), rowOf{cp(k)}(end+1) = rp(k); end
for c = 1:W, if ~isempty(rowOf{c}), rowOf{c} = sort(rowOf{c}(:))'; end, end
info = struct('thr',thr,'nComp',nk,'nSk0',nSk0,'nSk1',nSk1,'nSk',sum(sk(:)), ...
              'top',top,'bot',bot,'lft',lft,'rgt',rgt,'g',g,'ch',ch);
end
function v = getf2(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end
function sk = pruneSpurs(sk, Lmax, iters)
for it = 1:iters
   nc = conv2(double(sk), ones(3), 'same') - double(sk);
   jc = sk & nc >= 3; seg = sk & ~jc;
   [lb, n] = bwlabel(seg, 8); rm = false(size(sk));
   for k = 1:n
      idx = find(lb == k);
      if numel(idx) >= Lmax, continue; end
      [rr, cc] = ind2sub(size(sk), idx);
      touchJ = false; freeEnd = false;
      for q = 1:numel(idx)
         r0 = max(1,rr(q)-1); r1 = min(size(sk,1),rr(q)+1);
         c0 = max(1,cc(q)-1); c1 = min(size(sk,2),cc(q)+1);
         if any(any(jc(r0:r1, c0:c1))), touchJ = true; end
         if nc(rr(q), cc(q)) <= 1, freeEnd = true; end
      end
      if touchJ && freeEnd, rm(idx) = true; end
   end
   if ~any(rm(:)), break; end
   sk(rm) = false;
end
end
