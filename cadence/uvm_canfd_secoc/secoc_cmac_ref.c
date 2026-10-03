/* Independent AES-CMAC reference for the CAN-FD/SecOC UVM scoreboard. */
#include <stdint.h>

/* Reuse the already validated portable AES-128 C model in this repository. */
#include "../../verification/uvm_e2e/aes_ctr_ref.c"

static void cmac_double_bytes(const uint8_t in[16], uint8_t out[16]) {
    uint8_t carry = 0;
    for (int i = 15; i >= 0; --i) {
        uint8_t next = (uint8_t)(in[i] >> 7);
        out[i] = (uint8_t)((in[i] << 1) | carry);
        carry = next;
    }
    if (in[0] & 0x80u) out[15] ^= 0x87u;
}

static void xor_block(const uint8_t a[16], const uint8_t b[16], uint8_t out[16]) {
    for (int i = 0; i < 16; ++i) out[i] = (uint8_t)(a[i] ^ b[i]);
}

DPI_EXPORT void secoc_cmac_ref(
    uint32_t key3, uint32_t key2, uint32_t key1, uint32_t key0,
    uint32_t can_id, uint32_t ide, uint32_t fdf, uint32_t brs,
    uint32_t dlc, uint32_t freshness,
    uint32_t p15, uint32_t p14, uint32_t p13, uint32_t p12,
    uint32_t p11, uint32_t p10, uint32_t p9, uint32_t p8,
    uint32_t p7, uint32_t p6, uint32_t p5, uint32_t p4,
    uint32_t p3, uint32_t p2, uint32_t p1, uint32_t p0,
    uint32_t *tag3, uint32_t *tag2, uint32_t *tag1, uint32_t *tag0
) {
    uint8_t key[16], zero[16] = {0}, l[16], k1[16], x[16] = {0};
    uint8_t block[5][16], mixed[16], out[16];
    uint64_t header_low;

    words_to_bytes(key3, key2, key1, key0, key);

    header_low = ((uint64_t)(can_id & 0x1fffffffu) << 35) |
                 ((uint64_t)(ide & 1u) << 34) |
                 ((uint64_t)(fdf & 1u) << 33) |
                 ((uint64_t)(brs & 1u) << 32) |
                 ((uint64_t)(dlc & 0xfu) << 28);
    words_to_bytes(0x5345434fu, freshness,
                   (uint32_t)(header_low >> 32), (uint32_t)header_low,
                   block[0]);
    words_to_bytes(p3,  p2,  p1,  p0,  block[1]);
    words_to_bytes(p7,  p6,  p5,  p4,  block[2]);
    words_to_bytes(p11, p10, p9,  p8,  block[3]);
    words_to_bytes(p15, p14, p13, p12, block[4]);

    aes128_encrypt(zero, key, l);
    cmac_double_bytes(l, k1);

    for (int block_index = 0; block_index < 5; ++block_index) {
        if (block_index == 4) {
            for (int i = 0; i < 16; ++i) block[4][i] ^= k1[i];
        }
        xor_block(x, block[block_index], mixed);
        aes128_encrypt(mixed, key, out);
        for (int i = 0; i < 16; ++i) x[i] = out[i];
    }

    *tag3 = bytes_word(&x[0]);
    *tag2 = bytes_word(&x[4]);
    *tag1 = bytes_word(&x[8]);
    *tag0 = bytes_word(&x[12]);
}
