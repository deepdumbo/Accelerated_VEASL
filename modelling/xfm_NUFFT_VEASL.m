classdef xfm_NUFFT_VEASL < xfm
%   NUFFT Linear Operator for Vessel-Encoded ASL
%   Forward transforms vessel components to encoded images to multi-coil, arbitrary non-Cartesian k-space
%   along with the adjoint (multi-coil k-space to coil combined images decoded for vessel components)
%
%   Based on work by:
%   Mark Chiew
%   mchiew@fmrib.ox.ac.uk
%   July 2015
%   
%   Edited by:
%   Sophie Schauman
%   sophie.schauman@dtc.ox.ac.uk
%   March 2018
%
%   NB: Requires the nufft portion of Jeff Fessler's irt toolbox
%       See http://web.eecs.umich.edu/~fessler/irt/fessler.tgz
%
%   Required Inputs:
%       dims    =   [Nx, Ny, Nz, Nt] 4D vector of image dimensions
%       k       =   [Nsamp, Nt, 2] (2D) or [Nsamp, Nt, 3] (3D) 
%                   array of sampled k-space positions
%                   (in radians, normalised range -pi to pi)
%
%   Optional Inputs:
%       coils   =   [Nx, Ny, Nz, Nc] array of coil sensitivities 
%                   Defaults to single channel i.e. ones(Nx,Ny,Nz)
%       wi      =   Density compensation weights
%       Jd      =   Size of interpolation kernel
%                   Defaults to [6,6]
%       Kd      =   Size of upsampled grid
%                   Defaults to 200% of image size
%       shift   =   NUFFT shift factor
%                   Defaults to 50% of image size
%       VEMat   =   Vessel encoding matrix
%                   Defaults to standard asl tag-control scheme, hadamard(2);
%
%   Usage:
%           Forward transforms can be applied using the "*" or ".*" operators
%           or equivalently the "mtimes" or "times" functions
%           The input can be either the "Casorati" matrix (Nx*Ny*Nz, Nt) or
%           an n-d image array
%           The adjoint transform can be accessed by transposing the transform
%           object 
%           The difference between "*" and ".*" is only significant for the 
%           adjoint transform, and changes  the shape of the image ouptut:
%               "*" produces data that is in matrix form (Nx*Ny*Nz, Nt) whereas
%               ".*" produces data in n-d  array form (Nx, Ny, Nz, Nt) 

properties (SetAccess = protected, GetAccess = public)
    k       =   [];
    w       =   [];
    norm    =   1;
    Jd      =   [6,6];
    Kd      =   [];
    shift   =   [];
    st;
    Nvc     =   []; % number of vessel components
    Nenc    =   []; % number of vessel encodings
    VEMat   =   [];
    
end

methods
function res = xfm_NUFFT_VEASL(dims, coils, fieldmap_struct, k, H, varargin)

    %   Base class constructor
    res =   res@xfm(dims, coils, fieldmap_struct);
    
    if isempty(H)
        H   =   1;
    end
        res.VEMat   =   vesselEncodingMatrix(H, dims);
        res.Nvc  =   size(H,2);
        res.Nenc  =   size(H,1);
    
    %   Parse remaining inputs
    p   =   inputParser;

    %   Input validation functions
    lengthValidator =   @(x) length(x) == 2 || length(x) == 3;

    %   Input options
    p.addParamValue('wi',       [],                     @(x) size(x,2) == dims(4)||isscalar(x));
    p.addParamValue('Jd',       [6,6,6],                lengthValidator);
    p.addParamValue('Kd',       2*dims(1:3),            lengthValidator);
    p.addParamValue('shift',    floor(dims(1:3)/2),     lengthValidator);
    p.addParamValue('mean',     true,                   @islogical);
    p.addParamValue('lowmem',   false,                   @islogical);

    p.parse(varargin{:});
    p   =   p.Results;

    res.Jd      =   p.Jd;
    res.Kd      =   p.Kd;
    res.shift   =   p.shift;
    

    res.k       =   k;
    res.dsize   =   [size(k,1) res.Nt res.Nenc res.Nc ];
    res.msize   =   [prod(res.Nd), res.Nt, res.Nvc];

    disp('Initialising NUFFT(s)');
    nd  =   (res.Nd(3) > 1) + 2;
    for t = res.Nt:-1:1
        for enc = res.Nenc:-1:1
            if p.lowmem
                st(t,enc)   =   nufft_init(squeeze(k(:, t, enc, 1:nd)),...
                                   res.Nd(1:nd),...
                                   p.Jd(1:nd),...
                                   p.Kd(1:nd),...
                                   p.shift(1:nd),...
                                   'table',2^11,'minmax:kb');
            else
                st(t,enc)   =   nufft_init(squeeze(k(:, t, enc, 1:nd)),...
                   res.Nd(1:nd),...
                   p.Jd(1:nd),...
                   p.Kd(1:nd),...
                   p.shift(1:nd));
            end
        end
    end
    res.st  =   st;
    if isempty(p.wi)
    disp('Generating Density Compensation Weights');
    %   Use (Pipe 1999) fixed point method
        for t = 1:res.Nt
            for enc = 1:res.Nenc
                res.w(:,t,enc)  =   ones(size(k,1),1,1);
                for ii = 1:5
                    if p.lowmem
                        res.w(:,t,enc)  =   res.w(:,t,enc)./real(res.st(t,enc).interp_table(res.st(t,enc),res.st(t,enc).interp_table_adj(res.st(t,enc),res.w(:,t,enc))));
                    else
                        res.w(:,t,enc)  =   res.w(:,t,enc)./real(res.st(t,enc).p*(res.st(t,enc).p'*res.w(:,t,enc)));
                    end
                end
            end
        end
    elseif p.wi == 0
        disp('Generating Density Compensation Weights (same for each acquisition)');
        w   =   ones(size(k,1),1);
        for ii = 1:5
            w  =   w./real(res.st(1).p*(res.st(1).p'*w));
        end
        res.w = repmat(w,1,res.Nt);
        res.w = repmat(res.w,1,1,res.Nenc);
    elseif isscalar(p.wi)
        res.w   =   repmat(p.wi, 1, res.Nt);
        res.w   =   repmat(res.w,3,res.Nenc);
    else
        res.w   =   reshape(p.wi, [], res.Nt, res.Nenc);
    end
    res.w       =   sqrt(res.w);
    res.norm    =   sqrt(res.st(1).sn(ceil(end/2),ceil(end/2),ceil(end/2))^(-2)/prod(res.st(1).Kd));


end

function T = calcToeplitzEmbedding(a,idx)
    %   
    %   Should work on arbitrary shaped 3D [Nx, Ny, Nz] problems
    %   
    %   Computes first column of the block-circulant embedding for the block toeplitz A'A
    %   Need to use NUFFT twice to get 2 columns of A'A to do this
    %   A'A is conjugate symmetric, but within toeplitz blocks are NOT symmetric
    %
    %   First compute circulant embeddings for each Toeplitz block
    %   Then compute block-circulant embedding across blocks
    %
    %   Here's a 2D, 2x2 example
    %
    %   Block Toeplitz T=A'A 4x4 matrix (2x2 blocks of 2x2):
    %
    %                               a b'| c'd'
    %                               b a | e'c'      
    %                               --- + ---
    %                               c e | a b' 
    %                               d c | b a
    %
    %   Note this matrix is globally conjugate symmetric, and the block structure is also,
    %   but within each block they are not (at least not for the off-diagonal blocks)
    %   
    %   To get all the degrees of freedom, we need the first column and Nth column (where N
    %   is one of the dimensions. i.e., we need the first and last column of a column-block
    %
    %   This are easily estimated from A'A*[1;0;0;0] and A'A*[0;1;0;0]
    %
    %   Now we want to construct the first column of the block circulant embedding:
    %   The block circulant embedding C is constructed by first embedding each block within
    %   its circulant embedding (we use 0 for the arbitrary point):
    %
    %                               a b'0 b | c'd'0 e'
    %                               b a b'0 | e'c'd'0
    %                               0 b a b'| 0 e'c'd'
    %                               b'0 b a | d'0 e'c'
    %                               ------- + -------
    %                               c e 0 d | a b'0 b
    %                               d c e 0 | b a b'0
    %                               0 d c e | 0 b a b'
    %                               e 0 d c | b'0 b a
    %                               
    %   and then constructing the block-level embedding:
    %
    %                               a b'0 b | c'd'0 e'| 0 0 0 0 | c e 0 d
    %                               b a b'0 | e'c'd'0 | 0 0 0 0 | d c e 0
    %                               0 b a b'| 0 e'c'd'| 0 0 0 0 | 0 d c e
    %                               b'0 b a | d'0 e'c'| 0 0 0 0 | e 0 d c
    %                               ------- + ------- + ------- + -------
    %                               c e 0 d | a b'0 b | c'd'0 e | 0 0 0 0
    %                               d c e 0 | b a b'0 | e'c'd'0 | 0 0 0 0
    %                               0 d c e | 0 b a b'| 0 e'c'd | 0 0 0 0
    %                               e 0 d c | b'0 b a | d'0 e'c | 0 0 0 0
    %                               ------- + ------- + ------- + -------
    %                               0 0 0 0 | c e 0 d | a b'0 b | c'd'0 e
    %                               0 0 0 0 | d c e 0 | b a b'0 | e'c'd'0
    %                               0 0 0 0 | 0 d c e | 0 b a b'| 0 e'c'd
    %                               0 0 0 0 | e 0 d c | b'0 b a | d'0 e'c
    %                               ------- + ------- + ------- + -------
    %                               c'd'0 e'| 0 0 0 0 | c e 0 d | a b'0 b 
    %                               e'c'd'0 | 0 0 0 0 | d c e 0 | b a b'0 
    %                               0 e'c'd'| 0 0 0 0 | 0 d c e | 0 b a b'
    %                               d'0 e'c'| 0 0 0 0 | e 0 d c | b'0 b a 
    %
    %   In general, for an NxN image, we get an N^2 x N^2 Block-Toeplitz matrix (NxN blocks of NxN),
    %   and the circulant embedding is (2^d)N^2 x (2^d)N^2, where d=dimension (2 in this case)
    %   so that the total dimension is 4N^2 x 4N^2
    %
    %   Multiplication by this block-circulant matrix is completely characterised by its first column
    %   That is, the diagonalisation C = F*DF, where F are DFTs (where we can use FFT for O(N log N) 
    %   multiplication rather than O(N^2), and diag(D) = FFT(C(:,1))
    %   Intuitively, consider that circulant matrices perform circular convolutions, so that appealing
    %   to the Fourier convolution theorem, we can simply perform FFTs, point-wise multiply, and iFFT back
    %
    %   Because the upper left 
    %
    %   Practically, the first column of C is completely determined by the two columns of A'A we extracted
    %   Then C(:,1) should be reshaped into an 2Nx2N PSF tensor:
    %
    %                               a 
    %                               b
    %                               0
    %                               b
    %                               c   
    %                               d     a c 0 c'
    %                               0     b d 0 e'
    %                               e  =  0 0 0 0
    %                               0     b'e 0 d'
    %                               0    
    %                               0    
    %                               0
    %                               c
    %                               e
    %                               0
    %                               d
    %
    %   While we don't FFTshift in practice, shifting this 2D tensor makes its nature as a PSF more evident:
    %   
    %                                   0 0 0 0 
    %                                   0 d'b'e
    %                                   0 c'a c
    %                                   0'e'b d
    %                           
    %   Once constructed, then A'A*x can be computed via iFFT(FFT(PSF).*FFT(padarray(x)))
    %   This greatly speeds up computation of A'Ax, from O(N^2) to O(N log N)

    %       Explicit 3D example (2x2x2) 
    %       Symmetric 3-level 8x8 block Toeplitz A'A matrix
    %       
    %       a b'| c'd'| f'j'| l'n'
    %       b a | e'c'| g'f'| m'l'
    %       --- + --- + --- + ---
    %       c e | a b'| h'k'| f'j'
    %       d c | b a | i'h'| g'f'
    %       --- + --- + --- + ---
    %       f g | h i | a b'| c'd'
    %       j f | k h | b a | e'c'
    %       --- + --- + --- + ---
    %       l m | f g | c e | a b'
    %       n l | j f | d c | b a
    %
    %       Step 1 of circulant embedding:
    %       Circulant embed each of the lowest scale 2x2 Toeplitz blocks 
    %       (2x8) x (2x8)
    %
    %       a b'0 b | c'd'0 e'| f'j'0 g'| l'n'0 m'
    %       b a b'0 | e'c'd'0 | g'f'j'0 | m'l'n'0
    %       0 b a b'| 0 e'c'd'| 0 g'f'j'| 0 m'l'n'
    %       b'0 b a | d'0 e'c'| j'0 g'f'| n'0 m'l'
    %       ------- + ------- + ------- + -------
    %       c e 0 d | a b'0 b | h'k'0 i'| f'j'0 g'
    %       d c e 0 | b a b'0 | i'h'k'0 | g'f'j'0 
    %       0 d c e | 0 b a b'| 0 i'h'k'| 0 g'f'j'
    %       e 0 d c | b'0 b a | k'0 i'h'| j'0 g'f'
    %       ------- + ------- + ------- + -------
    %       f g 0 j | h i 0 k | a b'0 b | c'd'0 e'
    %       j f g 0 | k h i 0 | b a b'0 | e'c'd'0 
    %       0 j f g | 0 k h i | 0 b a b'| 0 e'c'd'
    %       g 0 j f | i 0 k h | b'0 b a | d'0 e'c'
    %       ------- + ------- + ------- + ------- 
    %       l m 0 n | f g 0 j | c e 0 d | a b'0 b 
    %       n l m 0 | j f g 0 | d c e 0 | b a b'0 
    %       0 n l m | 0 j f g | 0 d c e | 0 b a b'
    %       m 0 n l | g 0 j f | e 0 d c | b'0 b a 
    %
    %       Step 2 of circulant embedding:
    %       Circulant embed each of the second level 8x8 block Toeplitz blocks
    %       (4x8) x (4x8)
    %
    %       a b'0 b   c'd'0 e'  0 0 0 0   c e 0 d | f'j'0 g'  l'n'0 m'  0 0 0 0   h'k'0 i'
    %       b a b'0   e'c'd'0   0 0 0 0   d c e 0 | g'f'j'0   m'l'n'0   0 0 0 0   i'h'k'0 
    %       0 b a b'  0 e'c'd'  0 0 0 0   0 d c e | 0 g'f'j'  0 m'l'n'  0 0 0 0   0 i'h'k'
    %       b'0 b a   d'0 e'c'  0 0 0 0   e 0 d c | j'0 g'f'  n'0 m'l'  0 0 0 0   k'0 i'h'
    %                                             |                                      
    %       c e 0 d   a b'0 b   c'd'0 e   0 0 0 0 | h'k'0 i'  f'j'0 g'  l'n'0 m'  0 0 0 0
    %       d c e 0   b a b'0   e'c'd'0   0 0 0 0 | i'h'k'0   g'f'j'0   m'l'n'0   0 0 0 0
    %       0 d c e   0 b a b'  0 e'c'd   0 0 0 0 | 0 i'h'k'  0 g'f'j'  0 m'l'n'  0 0 0 0
    %       e 0 d c   b'0 b a   d'0 e'c   0 0 0 0 | k'0 i'h'  j'0 g'f'  n'0 m'l'  0 0 0 0
    %                                             |                                       
    %       0 0 0 0   c e 0 d   a b'0 b   c'd'0 e | f'j'0 g'  l'n'0 m'  0 0 0 0   h'k'0 i'
    %       0 0 0 0   d c e 0   b a b'0   e'c'd'0 | g'f'j'0   m'l'n'0   0 0 0 0   i'h'k'0 
    %       0 0 0 0   0 d c e   0 b a b'  0 e'c'd | 0 g'f'j'  0 m'l'n'  0 0 0 0   0 i'h'k'
    %       0 0 0 0   e 0 d c   b'0 b a   d'0 e'c | j'0 g'f'  n'0 m'l'  0 0 0 0   k'0 i'h'
    %                                             |                                        
    %       c'd'0 e'  0 0 0 0   c e 0 d   a b'0 b | l'n'0 m'  0 0 0 0   h'k'0 i'  f'j'0 g'
    %       e'c'd'0   0 0 0 0   d c e 0   b a b'0 | m'l'n'0   0 0 0 0   i'h'k'0   g'f'j'0 
    %       0 e'c'd'  0 0 0 0   0 d c e   0 b a b'| 0 m'l'n'  0 0 0 0   0 i'h'k'  0 g'f'j'
    %       d'0 e'c'  0 0 0 0   e 0 d c   b'0 b a | n'0 m'l'  0 0 0 0   k'0 i'h'  j'0 g'f'
    %       ------------------------------------- + -------------------------------------  
    %       f g 0 j   h i 0 k   0 0 0 0   l m 0 n | a b'0 b   c'd'0 e'  0 0 0 0   c e 0 d
    %       j f g 0   k h i 0   0 0 0 0   n l m 0 | b a b'0   e'c'd'0   0 0 0 0   d c e 0
    %       0 j f g   0 k h i   0 0 0 0   0 n l m | 0 b a b'  0 e'c'd'  0 0 0 0   0 d c e
    %       g 0 j f   i 0 k h   0 0 0 0   m 0 n l | b'0 b a   d'0 e'c'  0 0 0 0   e 0 d c
    %                                             |                                        
    %       l m 0 n   f g 0 j   h i 0 k   0 0 0 0 | c e 0 d   a b'0 b   c'd'0 e   0 0 0 0
    %       n l m 0   j f g 0   k h i 0   0 0 0 0 | d c e 0   b a b'0   e'c'd'0   0 0 0 0
    %       0 n l m   0 j f g   0 k h i   0 0 0 0 | 0 d c e   0 b a b'  0 e'c'd   0 0 0 0
    %       m 0 n l   g 0 j f   i 0 k h   0 0 0 0 | e 0 d c   b'0 b a   d'0 e'c   0 0 0 0
    %                                             |                                        
    %       0 0 0 0   l m 0 n   f g 0 j   h i 0 k | 0 0 0 0   c e 0 d   a b'0 b   c'd'0 e
    %       0 0 0 0   n l m 0   j f g 0   k h i 0 | 0 0 0 0   d c e 0   b a b'0   e'c'd'0
    %       0 0 0 0   0 n l m   0 j f g   0 k h i | 0 0 0 0   0 d c e   0 b a b'  0 e'c'd
    %       0 0 0 0   m 0 n l   g 0 j f   i 0 k h | 0 0 0 0   e 0 d c   b'0 b a   d'0 e'c
    %                                             |                                        
    %       h i 0 k   0 0 0 0   l m 0 n   f g 0 j | c'd'0 e'  0 0 0 0   c e 0 d   a b'0 b
    %       k h i 0   0 0 0 0   n l m 0   j f g 0 | e'c'd'0   0 0 0 0   d c e 0   b a b'0
    %       0 k h i   0 0 0 0   0 n l m   0 j f g | 0 e'c'd'  0 0 0 0   0 d c e   0 b a b
    %       i 0 k h   0 0 0 0   m 0 n l   g 0 j f | d'0 e'c'  0 0 0 0   e 0 d c   b'0 b a
    %
    %       Step 3 of circulant embedding:
    %       Circulant embed the third level 16x16 block Toeplitz blocks
    %       (8x8) x (8x8)
    %
    %       a b'0 b   c'd'0 e'  0 0 0 0   c e 0 d | f'j'0 g'  l'n'0 m'  0 0 0 0   h'k'0 i'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | f g 0 j   h i 0 k   0 0 0 0   l m 0 n
    %       b a b'0   e'c'd'0   0 0 0 0   d c e 0 | g'f'j'0   m'l'n'0   0 0 0 0   i'h'k'0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | j f g 0   k h i 0   0 0 0 0   n l m 0
    %       0 b a b'  0 e'c'd'  0 0 0 0   0 d c e | 0 g'f'j'  0 m'l'n'  0 0 0 0   0 i'h'k'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 j f g   0 k h i   0 0 0 0   0 n l m
    %       b'0 b a   d'0 e'c'  0 0 0 0   e 0 d c | j'0 g'f'  n'0 m'l'  0 0 0 0   k'0 i'h'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | g 0 j f   i 0 k h   0 0 0 0   m 0 n l
    %                                             |                                       |                                       |                                      
    %       c e 0 d   a b'0 b   c'd'0 e   0 0 0 0 | h'k'0 i'  f'j'0 g'  l'n'0 m'  0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | l m 0 n   f g 0 j   h i 0 k   0 0 0 0
    %       d c e 0   b a b'0   e'c'd'0   0 0 0 0 | i'h'k'0   g'f'j'0   m'l'n'0   0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | n l m 0   j f g 0   k h i 0   0 0 0 0
    %       0 d c e   0 b a b'  0 e'c'd   0 0 0 0 | 0 i'h'k'  0 g'f'j'  0 m'l'n'  0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 n l m   0 j f g   0 k h i   0 0 0 0
    %       e 0 d c   b'0 b a   d'0 e'c   0 0 0 0 | k'0 i'h'  j'0 g'f'  n'0 m'l'  0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | m 0 n l   g 0 j f   i 0 k h   0 0 0 0
    %                                             |                                       |                                       |                                      
    %       0 0 0 0   c e 0 d   a b'0 b   c'd'0 e | f'j'0 g'  l'n'0 m'  0 0 0 0   h'k'0 i'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   l m 0 n   f g 0 j   h i 0 k
    %       0 0 0 0   d c e 0   b a b'0   e'c'd'0 | g'f'j'0   m'l'n'0   0 0 0 0   i'h'k'0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   n l m 0   j f g 0   k h i 0
    %       0 0 0 0   0 d c e   0 b a b'  0 e'c'd | 0 g'f'j'  0 m'l'n'  0 0 0 0   0 i'h'k'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   0 n l m   0 j f g   0 k h i
    %       0 0 0 0   e 0 d c   b'0 b a   d'0 e'c | j'0 g'f'  n'0 m'l'  0 0 0 0   k'0 i'h'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   m 0 n l   g 0 j f   i 0 k h
    %                                             |                                       |                                       |                                      
    %       c'd'0 e'  0 0 0 0   c e 0 d   a b'0 b | l'n'0 m'  0 0 0 0   h'k'0 i'  f'j'0 g'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | h i 0 k   0 0 0 0   l m 0 n   f g 0 j
    %       e'c'd'0   0 0 0 0   d c e 0   b a b'0 | m'l'n'0   0 0 0 0   i'h'k'0   g'f'j'0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | k h i 0   0 0 0 0   n l m 0   j f g 0
    %       0 e'c'd'  0 0 0 0   0 d c e   0 b a b'| 0 m'l'n'  0 0 0 0   0 i'h'k'  0 g'f'j'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 k h i   0 0 0 0   0 n l m   0 j f g
    %       d'0 e'c'  0 0 0 0   e 0 d c   b'0 b a | n'0 m'l'  0 0 0 0   k'0 i'h'  j'0 g'f'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | i 0 k h   0 0 0 0   m 0 n l   g 0 j f
    %       ------------------------------------- + ------------------------------------- + ------------------------------------- + -------------------------------------
    %       f g 0 j   h i 0 k   0 0 0 0   l m 0 n | a b'0 b   c'd'0 e'  0 0 0 0   c e 0 d | f'j'0 g'  l'n'0 m'  0 0 0 0   h'k'0 i'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       j f g 0   k h i 0   0 0 0 0   n l m 0 | b a b'0   e'c'd'0   0 0 0 0   d c e 0 | g'f'j'0   m'l'n'0   0 0 0 0   i'h'k'0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       0 j f g   0 k h i   0 0 0 0   0 n l m | 0 b a b'  0 e'c'd'  0 0 0 0   0 d c e | 0 g'f'j'  0 m'l'n'  0 0 0 0   0 i'h'k'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       g 0 j f   i 0 k h   0 0 0 0   m 0 n l | b'0 b a   d'0 e'c'  0 0 0 0   e 0 d c | j'0 g'f'  n'0 m'l'  0 0 0 0   k'0 i'h'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %                                             |                                       |                                       |                                      
    %       l m 0 n   f g 0 j   h i 0 k   0 0 0 0 | c e 0 d   a b'0 b   c'd'0 e   0 0 0 0 | h'k'0 i'  f'j'0 g'  l'n'0 m'  0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       n l m 0   j f g 0   k h i 0   0 0 0 0 | d c e 0   b a b'0   e'c'd'0   0 0 0 0 | i'h'k'0   g'f'j'0   m'l'n'0   0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       0 n l m   0 j f g   0 k h i   0 0 0 0 | 0 d c e   0 b a b'  0 e'c'd   0 0 0 0 | 0 i'h'k'  0 g'f'j'  0 m'l'n'  0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       m 0 n l   g 0 j f   i 0 k h   0 0 0 0 | e 0 d c   b'0 b a   d'0 e'c   0 0 0 0 | k'0 i'h'  j'0 g'f'  n'0 m'l'  0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %                                             |                                       |                                       |                                      
    %       0 0 0 0   l m 0 n   f g 0 j   h i 0 k | 0 0 0 0   c e 0 d   a b'0 b   c'd'0 e | f'j'0 g'  l'n'0 m'  0 0 0 0   h'k'0 i'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       0 0 0 0   n l m 0   j f g 0   k h i 0 | 0 0 0 0   d c e 0   b a b'0   e'c'd'0 | g'f'j'0   m'l'n'0   0 0 0 0   i'h'k'0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       0 0 0 0   0 n l m   0 j f g   0 k h i | 0 0 0 0   0 d c e   0 b a b'  0 e'c'd | 0 g'f'j'  0 m'l'n'  0 0 0 0   0 i'h'k'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       0 0 0 0   m 0 n l   g 0 j f   i 0 k h | 0 0 0 0   e 0 d c   b'0 b a   d'0 e'c | j'0 g'f'  n'0 m'l'  0 0 0 0   k'0 i'h'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %                                             |                                       |                                       |                                      
    %       h i 0 k   0 0 0 0   l m 0 n   f g 0 j | c'd'0 e'  0 0 0 0   c e 0 d   a b'0 b | l'n'0 m'  0 0 0 0   h'k'0 i'  f'j'0 g'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       k h i 0   0 0 0 0   n l m 0   j f g 0 | e'c'd'0   0 0 0 0   d c e 0   b a b'0 | m'l'n'0   0 0 0 0   i'h'k'0   g'f'j'0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       0 k h i   0 0 0 0   0 n l m   0 j f g | 0 e'c'd'  0 0 0 0   0 d c e   0 b a b | 0 m'l'n'  0 0 0 0   0 i'h'k'  0 g'f'j'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       i 0 k h   0 0 0 0   m 0 n l   g 0 j f | d'0 e'c'  0 0 0 0   e 0 d c   b'0 b a | n'0 m'l'  0 0 0 0   k'0 i'h'  j'0 g'f'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0
    %       ------------------------------------- + ------------------------------------- + ------------------------------------- + -------------------------------------
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | f g 0 j   h i 0 k   0 0 0 0   l m 0 n | a b'0 b   c'd'0 e'  0 0 0 0   c e 0 d | f'j'0 g'  l'n'0 m'  0 0 0 0   h'k'0 i'
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | j f g 0   k h i 0   0 0 0 0   n l m 0 | b a b'0   e'c'd'0   0 0 0 0   d c e 0 | g'f'j'0   m'l'n'0   0 0 0 0   i'h'k'0 
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 j f g   0 k h i   0 0 0 0   0 n l m | 0 b a b'  0 e'c'd'  0 0 0 0   0 d c e | 0 g'f'j'  0 m'l'n'  0 0 0 0   0 i'h'k'
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | g 0 j f   i 0 k h   0 0 0 0   m 0 n l | b'0 b a   d'0 e'c'  0 0 0 0   e 0 d c | j'0 g'f'  n'0 m'l'  0 0 0 0   k'0 i'h'
    %                                             |                                       |                                       |                                       
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | l m 0 n   f g 0 j   h i 0 k   0 0 0 0 | c e 0 d   a b'0 b   c'd'0 e   0 0 0 0 | h'k'0 i'  f'j'0 g'  l'n'0 m'  0 0 0 0 
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | n l m 0   j f g 0   k h i 0   0 0 0 0 | d c e 0   b a b'0   e'c'd'0   0 0 0 0 | i'h'k'0   g'f'j'0   m'l'n'0   0 0 0 0 
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 n l m   0 j f g   0 k h i   0 0 0 0 | 0 d c e   0 b a b'  0 e'c'd   0 0 0 0 | 0 i'h'k'  0 g'f'j'  0 m'l'n'  0 0 0 0 
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | m 0 n l   g 0 j f   i 0 k h   0 0 0 0 | e 0 d c   b'0 b a   d'0 e'c   0 0 0 0 | k'0 i'h'  j'0 g'f'  n'0 m'l'  0 0 0 0 
    %                                             |                                       |                                       |                                       
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   l m 0 n   f g 0 j   h i 0 k | 0 0 0 0   c e 0 d   a b'0 b   c'd'0 e | 0 0 0 0   h'k'0 i'  f'j'0 g'  l'n'0 m'
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   n l m 0   j f g 0   k h i 0 | 0 0 0 0   d c e 0   b a b'0   e'c'd'0 | 0 0 0 0   i'h'k'0   g'f'j'0   m'l'n'0 
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   0 n l m   0 j f g   0 k h i | 0 0 0 0   0 d c e   0 b a b'  0 e'c'd | 0 0 0 0   0 i'h'k'  0 g'f'j'  0 m'l'n'
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   m 0 n l   g 0 j f   i 0 k h | 0 0 0 0   e 0 d c   b'0 b a   d'0 e'c | 0 0 0 0   k'0 i'h'  j'0 g'f'  n'0 m'l'
    %                                             |                                       |                                       |                                       
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | h i 0 k   0 0 0 0   l m 0 n   f g 0 j | c'd'0 e'  0 0 0 0   c e 0 d   a b'0 b | l'n'0 m'  0 0 0 0   h'k'0 i'  f'j'0 g'
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | k h i 0   0 0 0 0   n l m 0   j f g 0 | e'c'd'0   0 0 0 0   d c e 0   b a b'0 | m'l'n'0   0 0 0 0   i'h'k'0   g'f'j'0 
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 k h i   0 0 0 0   0 n l m   0 j f g | 0 e'c'd'  0 0 0 0   0 d c e   0 b a b | 0 m'l'n'  0 0 0 0   0 i'h'k'  0 g'f'j'
    %       0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | i 0 k h   0 0 0 0   m 0 n l   g 0 j f | d'0 e'c'  0 0 0 0   e 0 d c   b'0 b a | n'0 m'l'  0 0 0 0   k'0 i'h'  j'0 g'f'
    %       ------------------------------------- + ------------------------------------- + ------------------------------------- + -------------------------------------
    %       f'j'0 g'  l'n'0 m'  0 0 0 0   h'k'0 i'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | f g 0 j   h i 0 k   0 0 0 0   l m 0 n | a b'0 b   c'd'0 e'  0 0 0 0   c e 0 d
    %       g'f'j'0   m'l'n'0   0 0 0 0   i'h'k'0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | j f g 0   k h i 0   0 0 0 0   n l m 0 | b a b'0   e'c'd'0   0 0 0 0   d c e 0
    %       0 g'f'j'  0 m'l'n'  0 0 0 0   0 i'h'k'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 j f g   0 k h i   0 0 0 0   0 n l m | 0 b a b'  0 e'c'd'  0 0 0 0   0 d c e
    %       j'0 g'f'  n'0 m'l'  0 0 0 0   k'0 i'h'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | g 0 j f   i 0 k h   0 0 0 0   m 0 n l | b'0 b a   d'0 e'c'  0 0 0 0   e 0 d c
    %                                             |                                       |                                       |                                      
    %       h'k'0 i'  f'j'0 g'  l'n'0 m'  0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | l m 0 n   f g 0 j   h i 0 k   0 0 0 0 | c e 0 d   a b'0 b   c'd'0 e   0 0 0 0
    %       i'h'k'0   g'f'j'0   m'l'n'0   0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | n l m 0   j f g 0   k h i 0   0 0 0 0 | d c e 0   b a b'0   e'c'd'0   0 0 0 0
    %       0 i'h'k'  0 g'f'j'  0 m'l'n'  0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 n l m   0 j f g   0 k h i   0 0 0 0 | 0 d c e   0 b a b'  0 e'c'd   0 0 0 0
    %       k'0 i'h'  j'0 g'f'  n'0 m'l'  0 0 0 0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | m 0 n l   g 0 j f   i 0 k h   0 0 0 0 | e 0 d c   b'0 b a   d'0 e'c   0 0 0 0
    %                                             |                                       |                                       |                                      
    %       0 0 0 0   h'k'0 i'  f'j'0 g'  l'n'0 m'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   l m 0 n   f g 0 j   h i 0 k | 0 0 0 0   c e 0 d   a b'0 b   c'd'0 e
    %       0 0 0 0   i'h'k'0   g'f'j'0   m'l'n'0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   n l m 0   j f g 0   k h i 0 | 0 0 0 0   d c e 0   b a b'0   e'c'd'0
    %       0 0 0 0   0 i'h'k'  0 g'f'j'  0 m'l'n'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   0 n l m   0 j f g   0 k h i | 0 0 0 0   0 d c e   0 b a b'  0 e'c'd
    %       0 0 0 0   k'0 i'h'  j'0 g'f'  n'0 m'l'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 0 0 0   m 0 n l   g 0 j f   i 0 k h | 0 0 0 0   e 0 d c   b'0 b a   d'0 e'c
    %                                             |                                       |                                       |                                      
    %       l'n'0 m'  0 0 0 0   h'k'0 i'  f'j'0 g'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | h i 0 k   0 0 0 0   l m 0 n   f g 0 j | c'd'0 e'  0 0 0 0   c e 0 d   a b'0 b
    %       m'l'n'0   0 0 0 0   i'h'k'0   g'f'j'0 | 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | k h i 0   0 0 0 0   n l m 0   j f g 0 | e'c'd'0   0 0 0 0   d c e 0   b a b'0
    %       0 m'l'n'  0 0 0 0   0 i'h'k'  0 g'f'j'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | 0 k h i   0 0 0 0   0 n l m   0 j f g | 0 e'c'd'  0 0 0 0   0 d c e   0 b a b
    %       n'0 m'l'  0 0 0 0   k'0 i'h'  j'0 g'f'| 0 0 0 0   0 0 0 0   0 0 0 0   0 0 0 0 | i 0 k h   0 0 0 0   m 0 n l   g 0 j f | d'0 e'c'  0 0 0 0   e 0 d c   b'0 b a

    disp('Computing Toeplitz Embedding')
    Nd  =   a.Nd;
    Nt  =   a.Nt;
    Nenc = a.Nenc;
    st  =   a.st;
    w   =   a.w.^2;

    %   Need 2^(d-1) columns of A'A
    %   4 columns for 3D problems
    x1  =   zeros([Nd(1) prod(Nd(2:3)) Nt Nenc],'single');
    x2  =   zeros([Nd(1) prod(Nd(2:3)) Nt Nenc],'single');
    x3  =   zeros([Nd(1) prod(Nd(2:3)) Nt Nenc],'single');
    x4  =   zeros([Nd(1) prod(Nd(2:3)) Nt Nenc],'single');

    T   =   zeros(8*prod(Nd), Nt, Nenc, 'single');

    %   First column
    tmp =   zeros(Nd,'single');
    tmp(1,1,1)  =   1;
    for t = 1:Nt
        for enc = 1:Nenc
            x1(:,:,t,enc)   =   reshape(nufft_adj(w(:,t,enc).*nufft(tmp, st(t,enc)), st(t,enc)), Nd(1), []);
        end
    end

    %   Second column
    tmp =   zeros(Nd,'single');
    tmp(end,1,1)    =   1;
    for t = 1:Nt
        for enc = 1:Nenc
            x2(:,:,t,enc)   =   reshape(nufft_adj(w(:,t,enc).*nufft(tmp, st(t,enc)), st(t,enc)), Nd(1), []);
            x2(end,:,t, enc) =   0;
        end
    end

    %   Third column
    tmp =   zeros(Nd,'single');
    tmp(1,end,1)    =   1;
    for t = 1:Nt
        for enc = 1:Nenc
            x3(:,:,t,enc)   =   reshape(nufft_adj(w(:,t,enc).*nufft(tmp, st(t,enc)), st(t,enc)), Nd(1), []);
        end
    end

    %   Fourth column
    tmp =   zeros(Nd,'single');
    tmp(end,end,1)  =   1;
    for t = 1:Nt
        for enc = 1:Nenc
            x4(:,:,t,enc)   =   reshape(nufft_adj(w(:,t,enc).*nufft(tmp, st(t,enc)), st(t,enc)), Nd(1), []);
            x4(end,:,t,enc) =   0;
        end
    end

    %   Perform first level embedding
    M1  =   cat(1, x1, circshift(x2,1,1));
    clear x1 x2;
    M2  =   cat(1, x3, circshift(x4,1,1));
    clear x3 x4;


    %   Perform second level embedding
    M2  =   reshape(M2, [2*Nd(1) Nd(2:3) Nt Nenc]);
    M2(:,end,:,:,:)   =   0;
    M1  =   reshape(M1, [], Nd(3), Nt, Nenc);
    M2  =   reshape(M2, [], Nd(3), Nt, Nenc);
    M3  =   cat(1, M1,  circshift(M2,2*Nd(1),1));
    
    clear M1 M2;

    %   Perform third (final) level embedding
    M3  =   reshape(M3, 2*Nd(1), 2*Nd(2), Nd(3), Nt, Nenc);

    T(1:4*prod(Nd),:,:) = reshape(M3, [], Nt, Nenc);

    M3  =   circshift(flipdim(M3,3),1,3);
    M3  =   circshift(flipdim(M3,2),1,2);
    M3  =   circshift(flipdim(M3,1),1,1);

    for i = 1
        T(4*prod(Nd)+4*(i-1)*prod(Nd(1:2))+1:4*prod(Nd)+4*i*prod(Nd(1:2)),:,:)    =   0;
    end
    for i = 2:Nd(3)
        T(4*prod(Nd)+4*(i-1)*prod(Nd(1:2))+1:4*prod(Nd)+4*i*prod(Nd(1:2)),:,:)    =   conj(reshape(M3(:,:,i,:,:),[],Nt, Nenc));
    end

    T   =   prod(sqrt(2*Nd))*a.fftfn_ns(reshape(T,[2*Nd Nt Nenc]), 1:3)*a.norm^2;

end


function b = mtimes_Toeplitz(a,T,b,w)
    Nt  =   size(T,4);
    Nd  =   a.Nd;
    S   =   a.S;
    Nenc =  a.Nenc;
    
    b   =   a.VEMat*b;
    b   =   reshape(b,[],Nt, a.Nenc);
    tmp =   zeros(2*Nd(1),2*Nd(2),2*Nd(3),1,1,a.Nc,'single');
    for t = 1:Nt
        for enc = 1:Nenc
            tmp(1:Nd(1),1:Nd(2),1:Nd(3),1,1,:)  =  S*b(:,t,enc);
            tmp    =   ifftn(T(:,:,:,t,enc).*fftn(tmp)); 
            b(:,t,enc)  =   reshape(S'*tmp(1:Nd(1),1:Nd(2),1:Nd(3),1,1,:),[],1);
            tmp =   zeros(2*Nd(1),2*Nd(2),2*Nd(3),1,1,a.Nc,'single');     
        end
    end
    clear tmp
    % reshape b before encoding?
    b = a.VEMat'*b;
end

function res = mtimes(a,b)

    %   Property access in MATLAB classes is very slow, so any property accessed
    %   more than once is copied into the local scope first
    nt   =   a.Nt;
    Nenc =   a.Nenc;
%     st   =   a.st;
    w    =   a.w;

    if a.adjoint
    %   Adjoint NUFFT and coil transform
%         res =   zeros([a.Nd, nt a.Nvc a.Nc]);
        tmp =   zeros([a.Nd, nt a.Nenc a.Nc],'single');
        for t = 1:nt
            for enc = 1:Nenc
                b(:,t,enc,:) = b(:,t, enc,:).*w(:,t,enc);
                tmp(:,:,:,t,enc,:)  =   nufft_adj(squeeze(b(:,t, enc, :)), a.st(t,enc));
            end
        end
        res =   reshape(a.norm*(a.S'*tmp), [a.Nd,nt,Nenc]); 
        clear tmp
        res = a.VEMat'*res;

        
    else
    %   Forward NUFFT and coil transform
        res =   zeros([a.dsize(1) nt Nenc, a.Nc ],'single');
        tmp = a.VEMat*b;
        tmp =   a.norm*(a.S*tmp);
        % need to separate time and encoding dimension as the sensitivity
        % encoding operator merges all non spatial dimensions.
        tmp =   reshape(tmp, [a.Nd, a.Nt, a.Nenc,  a.Nc]);
        for t = 1:nt
            for enc = 1:a.Nenc
                res(:,t,enc,:)  =   nufft(squeeze(tmp(:,:,:,t,enc,:)), a.st(t,enc));
                res(:,t,enc,:)  = res(:,t,enc,:).*w(:,t,enc);
            end
        end
    end

end
%%%%%

function res = times(a,b)
    if a.adjoint
        res =   reshape(mtimes(a,b), [a.Nd(1:2) a.Nd(3), a.Nt, a.Nvc]);
    else
        res =   mtimes(a,b);
    end
end


% function res = mean(a,b)
%     nd  =   (a.Nd(3) > 1) + 2;
%     st  =   nufft_init(reshape(a.k,[],nd),...
%                        a.Nd(1:nd),...
%                        a.Jd(1:nd),...
%                        a.Kd(1:nd),...
%                        a.shift(1:nd));
%     %   Use (Pipe 1999) fixed point method
%     w   =   ones(numel(a.k)/nd,1);
%     for ii = 1:20
%         tmp =   st.p*(st.p'*w);
%         w   =   w./real(tmp);
%     end
%     w   =   w*sqrt(st.sn(ceil(end/2),ceil(end/2))^(-2)/prod(st.Kd));
%     res =   a.S'*(nufft_adj(bsxfun(@times, reshape(b,[],a.Nc), w), st));
% end

end
end
