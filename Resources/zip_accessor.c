#include <stdint.h>
#include <stddef.h>

extern uint8_t zip_data_start[];
extern uint8_t zip_data_end[];

uint8_t* get_zip_data_ptr(void) { return zip_data_start; }
size_t get_zip_data_size(void) { return (size_t)(zip_data_end - zip_data_start); }
