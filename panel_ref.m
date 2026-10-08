function R = panel_ref(imageFile, img)
%PANEL_REF  识别已知单幅图，返回实测轴框/量程/遮挡框/期望条数
%   ① 先按文件名匹配（fig2E.png 或 fig2E_conv.png 都行）
%   ② 文件名不认识时，用 32x32 灰度指纹做**内容匹配**：同一张图哪怕改了名、
%      放在别的目录、重新存过，也能认出来（避免误退到种子链路导致结果不同）
%   R.found / R.tag / R.frame / R.range / R.block / R.nExpect / R.matched / R.err
R = struct('found',false,'tag','','frame',[],'range',[],'block',[],'nExpect',[],'refSize',[], ...
           'matched','','err','');
blkT = struct('fig2E',[1090 1270 860 2080], 'fig3B',[840 1250 1220 2226], ...
              'fig3C',[840 1265 1310 2339], 'fig3E',[210 600 1150 2165]);
here = fileparts(mfilename('fullpath'));
try
   S = fig_specs_v2();
   if ~isempty(imageFile)
      [~, b0] = fileparts(imageFile);
      b0n = strrep(b0, '_conv', '');
      for i = 1:numel(S)
         [~, bi] = fileparts(S(i).img);
         if strcmpi(bi, b0) || strcmpi(strrep(bi,'_conv',''), b0n)
            R = setFrom(R, S(i), blkT, 'name', fullfile(here,'data',S(i).img));
            return;
         end
      end
   end
   if nargin >= 2 && ~isempty(img)
      f0 = panel_fp(img);
      best = inf; bi = 0;
      for i = 1:numel(S)
         p = fullfile(here, 'data', S(i).img);
         if ~exist(p, 'file'), continue; end
         try
            fp = panel_fp(imread(p));      % 注意：MATLAB 不允许 f(...)(:) 这种连续索引
            d = max(abs(f0(:) - fp(:)));
            if d < best, best = d; bi = i; end
         catch
         end
      end
      if bi > 0 && best < 0.05
         R = setFrom(R, S(bi), blkT, sprintf('content %.3f', best), fullfile(here,'data',S(bi).img));
         return;
      end
      if isfinite(best)
         R.err = sprintf('内容指纹最佳差 %.3f（需 <0.05），不是这七张图之一', best);
      end
   end
catch ME
   R.err = ME.message;
end
end

function R = setFrom(R, s, blkT, how, refPath)
R.found = true; R.tag = s.tag; R.frame = s.frame; R.range = s.range;
R.nExpect = s.nExpect; R.matched = how;
if isfield(blkT, s.tag), R.block = blkT.(s.tag); end
% 参考图的像素尺寸：标定表里的轴框/遮挡框都是按这张图量的。
% 载入的图若尺寸不同（同一张图的不同分辨率），必须按比例缩放，否则整体偏移。
if nargin >= 5 && ~isempty(refPath)
   try
      info = imfinfo(refPath);
      R.refSize = [info(1).Height, info(1).Width];
   catch
   end
end
end

function f = panel_fp(I)
% 32x32 灰度指纹：与分辨率无关，同一张图（重存过也一样）几乎完全一致
if size(I,3) == 3, I = rgb2gray(I); end
f = im2double(imresize(I, [32 32]));
end
