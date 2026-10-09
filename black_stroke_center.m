function [y,detail]=black_stroke_center(I,cs,guide,fr)
% Locate both dark stroke edges, including gray overprinting between them.
% Full runs are measured before selecting the run near the traced path.
% No smoothing or polynomial fitting is applied to the observed centers.
d=double(I);if size(d,3)>1,d=mean(d,3);end
[H,W]=size(d);cs=cs(:);guide=guide(:);n=numel(cs);
measurement=nan(n,1);top=measurement;bottom=measurement;
scale=max(.25,(fr(2)-fr(1))/1227.39);gapLimit=max(2,round(18*scale));
search=max(16,round(60*scale));
rT=max(1,ceil(fr(1))+3);rB=min(H,floor(fr(2))-3);
for q=1:n
 c=round(cs(q));if c<1||c>W||~isfinite(guide(q)),continue;end
 rr=find(d(rT:rB,c)<95)+rT-1;if isempty(rr),continue;end
 cuts=find(diff(rr)>1);split=[];
 for j=cuts'
     bridge=d(rr(j)+1:rr(j+1)-1,c);
     if numel(bridge)>gapLimit||any(bridge>190),split(end+1)=j;end %#ok<AGROW>
 end
 ends=[0 split numel(rr)];best=inf;
 for j=1:numel(ends)-1
     run=rr(ends(j)+1:ends(j+1));a=run(1);b=run(end);
     distance=max([a-guide(q),guide(q)-b,0]);
     if distance>search||numel(run)<2,continue;end
     % Interpolated threshold crossings give symmetric subpixel edges.
     ta=a-.5;tb=b+.5;
     if a>rT&&d(a-1,c)>d(a,c),ta=a-1+(95-d(a-1,c))/(d(a,c)-d(a-1,c));end
     if b<rB&&d(b+1,c)>d(b,c),tb=b+(95-d(b,c))/(d(b+1,c)-d(b,c));end
     center=(ta+tb)/2;merit=distance+.05*abs(center-guide(q));
     if merit<best,best=merit;measurement(q)=center;top(q)=ta;bottom(q)=tb;end
 end
end
valid=isfinite(measurement);slope=zeros(n,1);
for q=1:n
 a=max(1,q-8);b=min(n,q+8);
 if isfinite(measurement(a))&&isfinite(measurement(b))&&cs(b)~=cs(a)
     slope(q)=(measurement(b)-measurement(a))/(cs(b)-cs(a));
 end
end
normalWidth=(bottom-top)./sqrt(1+slope.^2);
if any(valid)
 typical=median(normalWidth(valid));
 % A gray overprint may hide one edge. A partial dark fragment cannot supply
 % a center; bridge it using the intact neighboring stroke instead.
 valid=valid&normalWidth>=.6*typical&normalWidth<=1.9*typical;
 measurement(~valid)=NaN;
end
y=guide;y(valid)=measurement(valid);
% Only short internal overprinted gaps are connected between measured centers.
idx=find(valid);
for j=1:numel(idx)-1
 if cs(idx(j+1))-cs(idx(j))>max(10,round(30*scale)),continue;end
 missing=idx(j)+1:idx(j+1)-1;
 if ~isempty(missing),y(missing)=interp1(cs(idx(j:j+1)),measurement(idx(j:j+1)),cs(missing),'linear');end
end
detail=struct('measurement',measurement,'top',top,'bottom',bottom,'valid',valid);
end
