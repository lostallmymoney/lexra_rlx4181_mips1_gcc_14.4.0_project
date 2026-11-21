/* loop.c - the lexra_gcc_14.4_project optimization test vehicle.
 *
 * One source, built once per flag set (baseline -O2, -O3, then each
 * Graphite flag alone). Every snippet prints its own checksum line
 * ("lexra-test <name>=<value>") plus a final total, so a transform
 * that breaks ONE loop shape is visible by name instead of hiding
 * inside a single sum. All inputs are deterministic (a fixed LCG),
 * all math is integer, so every correct build prints byte-identical
 * output.
 *
 * Snippets, one per shape the optimizers meet:
 *   matmul      48x48 triple loop - interchange / blocking /
 *               strip-mine shaped.
 *   stencil     2D 5-point stencil, 20 sweeps - blocking shaped,
 *               neighbor accesses.
 *   reduction   sum + max over a strided array - the optimizer must
 *               preserve reduction semantics.
 *   conditional loop nest with a data-dependent if inside.
 *   nonaffine   inner bound driven by the data itself - Graphite
 *               must NOT transform this one; the control snippet.
 *   packed      walk over a packed struct array - what makes the
 *               poison build (-mno-strict-align) emit lwl/lwr/
 *               swl/swr; clean builds compose the same accesses
 *               from byte loads under -mstrict-align.
 */
#include <stdio.h>
#include <string.h>

static unsigned int rng_state = 0x12345678u;
static unsigned int rng(void)
{
    rng_state = rng_state * 1664525u + 1013904223u;
    return (rng_state >> 16) & 0x7fffu;
}

#define N 48
static int a[N][N], b[N][N], c[N][N];

static long snippet_matmul(void)
{
    int i, j, k;
    long sum = 0;
    for (i = 0; i < N; i++)
        for (j = 0; j < N; j++) {
            a[i][j] = (int)(rng() % 17) - 8;
            b[i][j] = (int)(rng() % 13) - 6;
            c[i][j] = 0;
        }
    for (i = 0; i < N; i++)
        for (j = 0; j < N; j++)
            for (k = 0; k < N; k++)
                c[i][j] += a[i][k] * b[k][j];
    for (i = 0; i < N; i++)
        for (j = 0; j < N; j++)
            sum += c[i][j];
    return sum;
}

#define S 64
static int grid[S][S], grid2[S][S];

static long snippet_stencil(void)
{
    int x, y, t;
    long sum = 0;
    for (y = 0; y < S; y++)
        for (x = 0; x < S; x++)
            grid[y][x] = (int)(rng() % 31);
    for (t = 0; t < 20; t++) {
        for (y = 1; y < S - 1; y++)
            for (x = 1; x < S - 1; x++)
                grid2[y][x] = (grid[y][x] * 2 + grid[y - 1][x]
                               + grid[y + 1][x] + grid[y][x - 1]
                               + grid[y][x + 1]) / 6;
        memcpy(grid, grid2, sizeof(grid));
    }
    for (y = 0; y < S; y++)
        for (x = 0; x < S; x++)
            sum += grid[y][x];
    return sum;
}

#define R 4096
static int arr[R];

static long snippet_reduction(void)
{
    int i;
    long sum = 0;
    int max = -1;
    for (i = 0; i < R; i++)
        arr[i] = (int)(rng() % 251);
    for (i = 0; i < R; i += 3) {
        sum += arr[i];
        if (arr[i] > max)
            max = arr[i];
    }
    return sum * 1000 + max;
}

static long snippet_conditional(void)
{
    int i, j;
    long sum = 0;
    for (i = 0; i < N; i++)
        for (j = 0; j < N; j++) {
            if ((a[i][j] & 1) == 0)
                c[i][j] = a[i][j] * 3 - b[i][j];
            else
                c[i][j] = a[i][j] + b[i][j] * 2;
            sum += c[i][j];
        }
    return sum;
}

static long snippet_nonaffine(void)
{
    int i, j;
    long sum = 0;
    for (i = 0; i < R; i++) {
        int bound = arr[i] % 23;
        for (j = 0; j < bound; j++)
            sum += (long)(arr[(i + j) % R] & 7);
    }
    return sum;
}

struct rec {
    unsigned char tag;
    unsigned int value;   /* deliberately unaligned: offset 1 */
    unsigned short tail;  /* offset 5 */
} __attribute__((packed));

static struct rec recs[257];

static long snippet_packed(void)
{
    int i;
    long sum = 0;
    for (i = 0; i < 257; i++) {
        recs[i].tag = (unsigned char)i;
        recs[i].value = rng() * 2654435761u;
        recs[i].tail = (unsigned short)(i * 37);
    }
    for (i = 0; i < 257; i++)
        sum += (long)(recs[i].value & 0xffffu) + recs[i].tail
             + recs[i].tag;
    return sum;
}

int main(void)
{
    long total = 0;
    long v;
    v = snippet_matmul();      total += v; printf("lexra-test matmul=%ld\n", v);
    v = snippet_stencil();     total += v; printf("lexra-test stencil=%ld\n", v);
    v = snippet_reduction();   total += v; printf("lexra-test reduction=%ld\n", v);
    v = snippet_conditional(); total += v; printf("lexra-test conditional=%ld\n", v);
    v = snippet_nonaffine();   total += v; printf("lexra-test nonaffine=%ld\n", v);
    v = snippet_packed();      total += v; printf("lexra-test packed=%ld\n", v);
    printf("lexra-test checksum=%ld\n", total);
    return 0;
}
