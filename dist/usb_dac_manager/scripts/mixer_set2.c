/* Set multi-value mixer via set_value and set_array; print gets. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tinyalsa/asoundlib.h>

int main(int argc, char **argv)
{
	struct mixer *m;
	struct mixer_ctl *c;
	unsigned card, i, n, argc_vals;
	int *vals;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <card> <ctl> <v0> [v1...]\n", argv[0]);
		return 1;
	}
	card = (unsigned)atoi(argv[1]);
	m = mixer_open(card);
	if (!m) {
		perror("mixer_open");
		return 1;
	}
	c = mixer_get_ctl_by_name(m, argv[2]);
	if (!c) {
		fprintf(stderr, "no ctl %s\n", argv[2]);
		mixer_close(m);
		return 1;
	}
	n = mixer_ctl_get_num_values(c);
	argc_vals = (unsigned)(argc - 3);
	fprintf(stderr, "ctl='%s' num=%u type=%s\n", argv[2], n,
		mixer_ctl_get_type_string(c));

	vals = calloc(n, sizeof(int));
	if (!vals)
		return 1;
	for (i = 0; i < n && i < argc_vals; i++)
		vals[i] = atoi(argv[i + 3]);

	/* Atomic array set first */
	if (mixer_ctl_set_array(c, vals, n) != 0)
		fprintf(stderr, "set_array FAIL\n");
	else {
		fprintf(stderr, "set_array ok →");
		for (i = 0; i < n; i++)
			fprintf(stderr, " %d", mixer_ctl_get_value(c, i));
		fprintf(stderr, "\n");
	}

	/* Per-index fallback */
	for (i = 0; i < n && i < argc_vals; i++) {
		if (mixer_ctl_set_value(c, i, vals[i]) != 0)
			fprintf(stderr, "set[%u]=%d FAIL\n", i, vals[i]);
		else
			fprintf(stderr, "set[%u]=%d get=%d\n", i, vals[i],
				mixer_ctl_get_value(c, i));
	}

	for (i = 0; i < n; i++)
		printf("%d%s", mixer_ctl_get_value(c, i), i + 1 < n ? "," : "\n");
	free(vals);
	mixer_close(m);
	return 0;
}
