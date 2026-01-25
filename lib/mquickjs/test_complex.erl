-module(test_complex).
-export([run/0]).

run() ->
    io:format("~n=== MQuickJS Complex Example ===~n~n"),

    {ok, Pid} = mquickjs:start_link(),
    io:format("JavaScript engine started~n~n"),

    %% Example 1: Prime number sieve
    io:format("--- Example 1: Sieve of Eratosthenes ---~n"),
    PrimeCode = <<"
        function sieve(max) {
            var isPrime = [];
            for (var i = 0; i <= max; i++) isPrime[i] = true;
            isPrime[0] = isPrime[1] = false;

            for (var i = 2; i * i <= max; i++) {
                if (isPrime[i]) {
                    for (var j = i * i; j <= max; j += i) {
                        isPrime[j] = false;
                    }
                }
            }

            var primes = [];
            for (var i = 2; i <= max; i++) {
                if (isPrime[i]) primes.push(i);
            }
            return primes;
        }
        sieve(50).join(',')
    ">>,
    {ok, Primes} = mquickjs:eval(Pid, PrimeCode),
    io:format("Primes up to 50: ~s~n~n", [Primes]),

    %% Example 2: Recursive quicksort
    io:format("--- Example 2: Quicksort Implementation ---~n"),
    SortCode = <<"
        function quicksort(arr) {
            if (arr.length <= 1) return arr;

            var pivot = arr[Math.floor(arr.length / 2)];
            var left = [];
            var middle = [];
            var right = [];

            for (var i = 0; i < arr.length; i++) {
                if (arr[i] < pivot) left.push(arr[i]);
                else if (arr[i] > pivot) right.push(arr[i]);
                else middle.push(arr[i]);
            }

            return quicksort(left).concat(middle).concat(quicksort(right));
        }

        var data = [64, 34, 25, 12, 22, 11, 90, 5, 77, 30];
        print('Original: ' + data.join(', '));
        var sorted = quicksort(data);
        print('Sorted:   ' + sorted.join(', '));
        sorted.join(',')
    ">>,
    {ok, Sorted} = mquickjs:eval(Pid, SortCode),
    {ok, SortOutput} = mquickjs:get_output(Pid),
    io:format("~s", [SortOutput]),
    io:format("Result: ~s~n~n", [Sorted]),

    %% Example 3: Object-oriented style - Bank Account
    io:format("--- Example 3: Object-Oriented Bank Account ---~n"),
    BankCode = <<"
        function BankAccount(name, initial) {
            return {
                name: name,
                balance: initial,
                deposit: function(amount) {
                    this.balance += amount;
                    print(this.name + ' deposited $' + amount + ', balance: $' + this.balance);
                },
                withdraw: function(amount) {
                    if (amount > this.balance) {
                        print(this.name + ' withdrawal of $' + amount + ' denied - insufficient funds');
                        return false;
                    }
                    this.balance -= amount;
                    print(this.name + ' withdrew $' + amount + ', balance: $' + this.balance);
                    return true;
                },
                transfer: function(other, amount) {
                    if (this.withdraw(amount)) {
                        other.deposit(amount);
                        print('Transfer complete');
                    }
                }
            };
        }

        var alice = BankAccount('Alice', 1000);
        var bob = BankAccount('Bob', 500);

        alice.deposit(200);
        bob.withdraw(100);
        alice.transfer(bob, 300);
        bob.withdraw(1000);  // Should fail

        'Alice: $' + alice.balance + ', Bob: $' + bob.balance
    ">>,
    {ok, BankResult} = mquickjs:eval(Pid, BankCode),
    {ok, BankOutput} = mquickjs:get_output(Pid),
    io:format("~s", [BankOutput]),
    io:format("Final balances: ~s~n~n", [BankResult]),

    %% Example 4: Closure and higher-order functions
    io:format("--- Example 4: Closures and Higher-Order Functions ---~n"),
    ClosureCode = <<"
        // Create a counter factory using closures
        function makeCounter(start) {
            var count = start;
            return {
                increment: function() { return ++count; },
                decrement: function() { return --count; },
                value: function() { return count; }
            };
        }

        // Higher-order function: map
        function map(arr, fn) {
            var result = [];
            for (var i = 0; i < arr.length; i++) {
                result.push(fn(arr[i]));
            }
            return result;
        }

        // Higher-order function: reduce
        function reduce(arr, fn, initial) {
            var acc = initial;
            for (var i = 0; i < arr.length; i++) {
                acc = fn(acc, arr[i]);
            }
            return acc;
        }

        // Higher-order function: filter
        function filter(arr, predicate) {
            var result = [];
            for (var i = 0; i < arr.length; i++) {
                if (predicate(arr[i])) result.push(arr[i]);
            }
            return result;
        }

        var counter = makeCounter(10);
        print('Counter: ' + counter.value());
        print('After 3 increments: ' + counter.increment() + ', ' + counter.increment() + ', ' + counter.increment());
        print('After decrement: ' + counter.decrement());

        var numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        var squared = map(numbers, function(x) { return x * x; });
        var sum = reduce(numbers, function(a, b) { return a + b; }, 0);
        var evens = filter(numbers, function(x) { return x % 2 === 0; });

        print('Numbers: ' + numbers.join(', '));
        print('Squared: ' + squared.join(', '));
        print('Sum: ' + sum);
        print('Evens: ' + evens.join(', '));

        'Sum of squares: ' + reduce(squared, function(a,b) { return a+b; }, 0)
    ">>,
    {ok, ClosureResult} = mquickjs:eval(Pid, ClosureCode),
    {ok, ClosureOutput} = mquickjs:get_output(Pid),
    io:format("~s", [ClosureOutput]),
    io:format("Result: ~s~n~n", [ClosureResult]),

    %% Example 5: String manipulation and RegExp
    io:format("--- Example 5: String Manipulation ---~n"),
    StringCode = <<"
        var text = 'The quick brown fox jumps over the lazy dog';

        print('Original: ' + text);
        print('Uppercase: ' + text.toUpperCase());
        print('Word count: ' + text.split(' ').length);

        // Reverse words
        var words = text.split(' ');
        var reversed = [];
        for (var i = words.length - 1; i >= 0; i--) {
            reversed.push(words[i]);
        }
        print('Reversed words: ' + reversed.join(' '));

        // Count vowels
        var vowels = 0;
        for (var i = 0; i < text.length; i++) {
            if ('aeiouAEIOU'.indexOf(text.charAt(i)) !== -1) vowels++;
        }
        print('Vowel count: ' + vowels);

        'Processed ' + text.length + ' characters'
    ">>,
    {ok, StringResult} = mquickjs:eval(Pid, StringCode),
    {ok, StringOutput} = mquickjs:get_output(Pid),
    io:format("~s", [StringOutput]),
    io:format("Result: ~s~n~n", [StringResult]),

    %% Example 6: Mathematical calculations
    io:format("--- Example 6: Mathematical Calculations ---~n"),
    MathCode = <<"
        // Calculate factorial
        function factorial(n) {
            if (n <= 1) return 1;
            return n * factorial(n - 1);
        }

        // Calculate combinations (n choose k)
        function combinations(n, k) {
            return factorial(n) / (factorial(k) * factorial(n - k));
        }

        // Newton's method for square root
        function sqrt_newton(x, precision) {
            var guess = x / 2;
            for (var i = 0; i < precision; i++) {
                guess = (guess + x / guess) / 2;
            }
            return guess;
        }

        print('Factorials: 5! = ' + factorial(5) + ', 10! = ' + factorial(10));
        print('Combinations: C(10,3) = ' + combinations(10, 3));
        print('Newton sqrt(2): ' + sqrt_newton(2, 10));
        print('Math.sqrt(2): ' + Math.sqrt(2));

        // Calculate pi using Leibniz formula (slow convergence)
        var pi = 0;
        for (var i = 0; i < 10000; i++) {
            pi += (i % 2 === 0 ? 1 : -1) / (2 * i + 1);
        }
        pi *= 4;
        print('Calculated pi: ' + pi);
        print('Math.PI: ' + Math.PI);

        'Calculations complete'
    ">>,
    {ok, MathResult} = mquickjs:eval(Pid, MathCode),
    {ok, MathOutput} = mquickjs:get_output(Pid),
    io:format("~s", [MathOutput]),
    io:format("Result: ~s~n~n", [MathResult]),

    %% Cleanup
    mquickjs:stop(Pid),
    io:format("=== Complex examples completed ===~n"),
    ok.
