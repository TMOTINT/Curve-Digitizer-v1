function [hit, val] = ocrCache(op, key, val)
%OCRCACHE  OCR 结果缓存（跨函数共享，避免同图重复识别）。
%
%   为什么单独成文件：ocrBridge.m 与 ocrBatch.m 都需要用它；若塞在其中一个
%   文件里当局部函数，另一个文件访问不到（MATLAB 局部函数只在文件内可见）。
%
%   用法：
%       [hit, res] = ocrCache('get', key)      % hit=true 时 res 可用
%       ocrCache('put', key, res)
%       ocrCache('clear')
%
%   key 由 ocrCacheKey 生成（图像指纹 + 关键参数）。

    persistent CACHE
    if isempty(CACHE)
        CACHE = containers.Map('KeyType','char','ValueType','any');
    end
    hit = false; 
    switch lower(op)
        case 'get'
            if isKey(CACHE, key)
                hit = true; val = CACHE(key);
            else
                val = [];
            end
        case 'put'
            if CACHE.Count > 40
                remove(CACHE, keys(CACHE));   % 简单限容，避免长会话里无限增长
            end
            CACHE(key) = val;
        case 'clear'
            remove(CACHE, keys(CACHE));
        otherwise
            error('ocrCache: 未知操作 %s', op);
    end
end
