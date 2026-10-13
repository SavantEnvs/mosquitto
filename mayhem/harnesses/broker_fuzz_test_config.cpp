#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

/* The broker fuzz-only main function: `mosquitto --test-config -c <file>` (upstream
 * fuzzing/broker/broker_fuzz_test_config.cpp, with a mkstemp() scratch file). */
extern "C" int mosquitto_fuzz_main(int argc, char *argv[]);

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const char *tmpdir = getenv("TMPDIR");
	char filename[4096];
	char *argv[4];
	int argc = 4;
	int fd;
	FILE *fptr;

	snprintf(filename, sizeof(filename), "%s/mosquitto_conf_XXXXXX", (tmpdir && *tmpdir) ? tmpdir : "/tmp");
	fd = mkstemp(filename);
	if(fd < 0) return -1;
	fptr = fdopen(fd, "wb");
	if(!fptr){
		close(fd);
		unlink(filename);
		return -1;
	}
	fwrite(data, 1, size, fptr);
	fclose(fptr);

	argv[0] = strdup("mosquitto");
	argv[1] = strdup("--test-config");
	argv[2] = strdup("-c");
	argv[3] = strdup(filename);

	mosquitto_fuzz_main(argc, argv);

	for(int i=0; i<argc; i++){
		free(argv[i]);
	}
	unlink(filename);

	return 0;
}
