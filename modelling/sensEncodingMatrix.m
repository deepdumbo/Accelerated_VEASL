classdef sensEncodingMatrix
%   Generates sparse stripe-diagonal sensitivity encoding matrix
%
%   Last Modified:
%   Mark Chiew
%   June 2014
%
%   Input:
%           sens    -   ND array of complex coil sensitivities
%                       Assumes 1st dimension is coils
%                       [Nx, Ny, Nz, Nc]

properties (SetAccess = private, GetAccess = private)

    adjoint =   0;
    ccoils  =   [];
end

properties (SetAccess = private, GetAccess = public)
    coils   =   [];
    dims    =   [];
    Nc      =   0;
end

methods
function res = sensEncodingMatrix(coils)

    res.dims(1) =   size(coils,1);
    res.dims(2) =   size(coils,2);
    res.dims(3) =   size(coils,3);
    res.Nc      =   size(coils,4);
    res.coils   =   reshape(coils,[res.dims 1 res.Nc]);
    res.ccoils  =   conj(res.coils);

end

function res = ctranspose(a)

    a.adjoint   = xor(a.adjoint,1);
    res         = a;

end

function res = mtimes(a,b,c)

    if nargin < 3
        c   =   1:a.Nc;
    end
    if a.adjoint
        %res =   sum(bsxfun(@times, reshape(b, a.dims(1), a.dims(2), a.dims(3), [], length(c)), a.ccoils(:,:,:,1,c)), 5);
        b   =   reshape(b, a.dims(1), a.dims(2), a.dims(3), [], length(c));
        res =   zeros([a.dims(1:3) size(b,4)]);
        cc  =   a.ccoils(:,:,:,1,c);
        for ii = 1:length(c)
            res =   res + bsxfun(@times, b(:,:,:,:,ii), cc(:,:,:,1,ii));
        end
    else
%         res =   bsxfun(@times, reshape(b, a.dims(1), a.dims(2), a.dims(3), []), a.coils(:,:,:,1,1,c));
        b = reshape(b,a.dims(1), a.dims(2), a.dims(3), []);
        res = zeros([a.dims(1:3), length(c)*size(b,4)]);
        cc  =   a.coils(:,:,:,1,c);
        cnt = 1;
        for ii = 1:length(c)
            res(:,:,:,cnt:cnt+size(b,4)-1) =   bsxfun(@times, b(:,:,:,:), cc(:,:,:,1,ii));
            cnt = cnt+size(b,4);
        end
    
    end

end

function res = mtimes_mb_adj_sens(a,res,b,step,nc)

    res = res + step*sum(b.*a.ccoils(:,nc), 2);

end
end
end
