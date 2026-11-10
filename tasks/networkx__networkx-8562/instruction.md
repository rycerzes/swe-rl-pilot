# Issue

**Title:** ENH: adding magnetic_laplacian_matrix

## Description

I added a `magnetic_laplacian_matrix` function on `networkx/linalg/laplacianmatrix.py`. I also added a test to verify it's workable. The Laplacian matrix works for `DiGraph` and `Graph`, nevertheless for an undirected graph returns a normal Laplacian Matrix. 

The Laplacian Matrix has been built as reference [1]. Here allows having weights on edges and does a mean in a symetrization process. The magnetic Laplacian is $L^{(q)}$, a Hermitian matrix associated to a directed graph $G=(V,E)$ with weights $w_{jk}$ for edges $(j,k)\in E$. Given a parameter $q\in [0, 1/2]$, it is defined as:

$$ L^{(q)} = D - A^{(q)}$$

where D is the degree of  the underlying undirected graph, and $A^{(q)}$ is the Hermitian Magnetic Adjacency Matrix defined as 

$$A^{(q)}_{jk} = w_{jk}'\cdot e^{2\pi iq\theta_{jk}}\cdot$$

where $w_{jk}'$ is $0$ if neither $(j,k)$ or $(j,k)$ are in $E$, and $(w_{jk}+w_{kj}))/2$ in other case, and $\theta_{jk}$ is either 1, -1 or 0 if the edge $(i,j)$ is in the specified direction, oposite or in both in $E$ respectively. 

If this contribution seems correct maybe it's a good idea to add spectral functions and normalized version. 

**References**
.. [1] Fanuel, M., Alaíz, C. M., Fernández, Á., & Suykens, J. A. (2018).
       Magnetic eigenmaps for the visualization of directed graphs.
       Applied and Computational Harmonic Analysis, 44(1), 189–199.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `db84a87dff15` and running the modified tests.