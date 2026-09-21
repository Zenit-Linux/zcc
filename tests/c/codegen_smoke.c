int printf(const char *fmt, ...);

struct Point {
    int x;
    int y;
};

enum Color { RED, GREEN = 5, BLUE };

int factorial(int n) {
    if (n <= 1) return 1;
    return n * factorial(n - 1);
}

int sum_array(int *arr, int n) {
    int total = 0;
    for (int i = 0; i < n; i++) {
        total += arr[i];
    }
    return total;
}

const char *color_name(enum Color c) {
    switch (c) {
        case RED: return "red";
        case GREEN: return "green";
        case BLUE: return "blue";
        default: return "unknown";
    }
}

int global_counter = 0;

void increment(void) {
    global_counter++;
}

int add(int a, int b) { return a + b; }
int mul(int a, int b) { return a * b; }
int apply(int (*fn)(int, int), int a, int b) { return fn(a, b); }

int main(void) {
    printf("factorial(10) = %d\n", factorial(10));

    int values[5] = {1, 2, 3, 4, 5};
    printf("sum = %d\n", sum_array(values, 5));

    struct Point p;
    p.x = 3;
    p.y = 4;
    struct Point *pp = &p;
    pp->x = 10;
    printf("point = (%d, %d)\n", p.x, p.y);

    enum Color c = GREEN;
    printf("color = %s\n", color_name(c));

    for (int i = 0; i < 5; i++) increment();
    printf("global_counter = %d\n", global_counter);

    printf("apply(mul) = %d\n", apply(mul, 6, 7));

    char buf[6] = "hello";
    printf("buf = %s\n", buf);

    return 0;
}
