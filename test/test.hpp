struct Bar {
    int _3;
};

namespace Foo {

template <typename T>
class Test {
  public:
    virtual ~Test();
    virtual void testingFunction(double delta);
    virtual void testingFunction(float delta);

    int testingItem;
    int* testingptr;
    char testingChar;

    void test() const;

    Test();
    Test(int i);
};

class Test2 : public Test<Bar> {
  public:
    void testingFunction(double delta) override;
    Test2();
    ~Test2();

    static const int bar;
};


};  // namespace Foo

float sum(float a, float b);
double sum(double a, double b);
template<typename T>
T sum(T a, T b);

template<>
int sum<int>(int j, int i);
