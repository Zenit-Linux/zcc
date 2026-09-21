typedef unsigned long size_t;

struct Point {
    int x;
    int y;
};

enum Color { RED, GREEN = 5, BLUE };

int add(int a, int b) {
    return a + b;
}

int factorial(int n) {
    if (n <= 1) {
        return 1;
    } else {
        return n * factorial(n - 1);
    }
}

int sum_array(int *arr, int n) {
    int total = 0;
    for (int i = 0; i < n; i++) {
        total += arr[i];
    }
    return total;
}

/* deklarator "na spirali": cmp to wskaźnik do funkcji(int,int)->int */
int apply(int (*cmp)(int, int), int a, int b) {
    return cmp(a, b);
}

int main(void) {
    struct Point p;
    p.x = 1;
    p.y = 2;

    int values[5] = {1, 2, 3, 4, 5};
    int s = sum_array(values, 5);

    int i = 0;
    while (i < 10) {
        i++;
        if (i == 3) continue;
        if (i == 8) break;
    }

    enum Color c = GREEN;
    size_t n = 10;

    return apply(add, s, n) + factorial(5) + (int)c;
}
