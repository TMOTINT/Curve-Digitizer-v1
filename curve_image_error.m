function report=curve_image_error(I,px,py,colors,fr,block,tag)
% Image-to-trace normal displacement, not experimental uncertainty.
% Missing ink, merged same-hue strokes and markers are unmeasurable (NaN).
if nargin<6,block=[];end
if nargin<7,tag='';end
d=double(I);if size(d,3)==1,d=repmat(d,1,1,3);end
[H,W,~]=size(d);n=numel(px);errors=cell(1,n);centers=cell(1,n);
mask=false(H,W);rT=max(1,ceil(fr(1))+3);rB=min(H,floor(fr(2))-3);
cL=max(1,ceil(fr(3))+3);cR=min(W,floor(fr(4))-3);mask(rT:rB,cL:cR)=true;
if ~isempty(block)
 b=round(block);mask(max(1,b(1)):min(H,b(2)),max(1,b(3)):min(W,b(4)))=false;
end
P=reshape(d,[],3);total=[];
for k=1:n
 x=px{k}(:);y=py{k}(:);m=nan(size(y));width=m;
 core=colors(k,:);isBlack=max(core)-min(core)<15;
 if isBlack
     V=max(0,(95-mean(d,3))/95).*mask;
 else
     v=255-core;alpha=max(0,min(1,(255-P)*v'/max(1,sum(v.^2))));
     residual=sum((255-P-alpha*v).^2,2);
     V=reshape(alpha.*exp(-residual/25^2),H,W).*mask;
 end
 if strcmp(tag,'fig2E')
     [~,detail]=black_stroke_center(I,x,y,fr);m=detail.measurement;
     width=detail.bottom-detail.top;
 else
     for q=1:numel(x)
         c=round(x(q));if c<1||c>W||~isfinite(y(q)),continue;end
         rr=find(V(:,c)>.2);if isempty(rr),continue;end
         cuts=[0;find(diff(rr)>1);numel(rr)];best=inf;
         for j=1:numel(cuts)-1
             run=rr(cuts(j)+1:cuts(j+1));w=V(run,c);
             center=sum(run.*w)/sum(w);distance=abs(center-y(q));
             if distance<best&&distance<=40
                 best=distance;m(q)=center;width(q)=numel(run);
             end
         end
     end
 end
 slope=zeros(size(y));
 for q=1:numel(x)
     a=max(1,q-3);b=min(numel(x),q+3);
     if x(b)~=x(a),slope(q)=(y(b)-y(a))/(x(b)-x(a));end
 end
 normalWidth=width./sqrt(1+slope.^2);valid=isfinite(m)&isfinite(y);
 if any(valid)
     base=max(2,prctile(normalWidth(valid),30));
     thick=normalWidth>max(base+3,1.8*base);
     if any(strcmp(tag,{'fig3B','fig3C','fig3E'}))
         thick=movmax(double(thick),[5 5])>0;
     end
     valid=valid&~thick;
 end
 for j=1:n
     if j==k||norm(colors(j,:)-core)>120,continue;end
     [ux,ia]=unique(px{j}(:));uy=py{j}(:);
     if numel(ux)<2,continue;end
     other=interp1(ux,uy(ia),x,'linear',NaN);
     valid=valid&(isnan(other)|abs(other-y)>10);
 end
 e=abs(y-m)./sqrt(1+slope.^2);e(~valid)=NaN;m(~valid)=NaN;
 errors{k}=e;centers{k}=m;total=[total;e(isfinite(e))]; %#ok<AGROW>
end
count=sum(cellfun(@numel,errors));
report=struct('errors',{errors},'centers',{centers},'nMeasured',numel(total), ...
 'nTotal',count,'median',NaN,'p95',NaN,'maximum',NaN);
if ~isempty(total)
 report.median=median(total);report.p95=prctile(total,95);report.maximum=max(total);
end
end
