---
title: 彻底理解volatile
description: 彻底理解volatile
date: 2022-03-28 15:15:00
# prev: ./04、彻底理解synchronized
# next: ./06、你真的了解final吗？
tags:
- 'Java'
- 'Java并发编程'
- 'JUC'
categories:
- '技术'
---

::: tip 说明

彻底理解volatile

:::

<!-- more -->

[[toc]]

# 彻底理解volatile

synchronized是阻塞式同步，在线程竞争激烈的情况下会升级为重量级锁。而volatile就可以说是java虚拟机提供的最轻量级的同步机制。但它同时不容易被正确理解，也至于在并发编程中很多程序员遇到线程安全的问题就会使用synchronized。[Java内存模型](https://github.com/Sentinel-22/concurrent/blob/master/3%E3%80%81Java%E5%86%85%E5%AD%98%E6%A8%A1%E5%9E%8B%E4%BB%A5%E5%8F%8Ahappens-before/Java%E5%86%85%E5%AD%98%E6%A8%A1%E5%9E%8B%E4%BB%A5%E5%8F%8Ahappens-before.md)告诉我们，各个线程会将共享变量从主内存中拷贝到工作内存，然后执行引擎会基于工作内存中的数据进行操作处理。线程在工作内存进行操作后何时会写到主内存中？这个时机对普通变量是没有规定的，而针对volatile修饰的变量给java虚拟机特殊的约定，线程对volatile变量的修改会立刻被其他线程所感知，即不会出现数据脏读的现象，从而保证数据的“可见性”。

现在我们有了一个大概的印象就是：**被volatile修饰的变量能够保证每个线程能够获取该变量的最新值，从而避免出现数据脏读的现象。**

## 1、volatile 的特性

理解volatile特性的一个好方法是把对volatile变量的单个读/写，看成是使用同一个锁对这些单个读/写操作做了同步。下面通过具体的示例来说明，示例代码如下。

```java
class VolatileFeaturesExample {
    volatile long vl = 0L; // 使用volatile声明64位的long型变量

    public void set(long l) {
        vl = l; // 单个volatile变量的写
    }
    public void getAndIncrement () {
        vl++; // 复合（多个）volatile变量的读/写
    }
    public long get() {
        return vl; // 单个volatile变量的读
    }
}
```

假设有多个线程分别调用上面程序的3个方法，这个程序在语义上和下面程序等价。

```java
class VolatileFeaturesExample {
    long vl = 0L; // 64位的long型普通变量

    public synchronized void set(long l) { // 对单个的普通变量的写用同一个锁同步
        vl = l;
    }
    public void getAndIncrement () { // 普通方法调用
        long temp = get(); // 调用已同步的读方法
        temp += 1L; // 普通写操作
        set(temp); // 调用已同步的写方法
    }
    public synchronized long get() { // 对单个的普通变量的读用同一个锁同步
        return vl;
    }
}
```

如上面示例程序所示，一个volatile变量的单个读/写操作，与一个普通变量的读/写操作都是使用同一个锁来同步，它们之间的执行效果相同。

简而言之，volatile变量自身具有下列特性：

- 可见性：对一个volatile变量的读，总是能看到（任意线程）对这个volatile变量最后的写入。
- 原子性：对任意单个volatile变量的读/写具有原子性，但类似于volatile++这种复合操作不具有原子性。

## 2、volatile 的实现原理

Java 语言规范第3版中对 volatile 的定义如下：

> Java 编程语言允许线程访问共享变量，为了确保共享变量能被准确和一致地更新，线程应该确保通过排他锁单独获得这个变量。

Java语言 提供了 volatile，在某些情况下比锁要更加方便。如果一个字段被声明成 volatile，Java线程内存模型确保所有线程看到这个变量的值是一致的。

在了解 volatile 实现原理之前，我们先来看下与其实现原理相关的 CPU 术语与说明。

 ![image-20220327164641390](./image/image-20220327164641390.png ':size=70%')

volatile 是如何来保证可见性的呢？让我们在 X86 处理器下通过工具获取JIT编译器生成的汇编指令来查看对 volatile 进行写操作时，CPU会做什么事情。

Java 代码：

```java
instance = new Instancce() //instance是volatile变量
```

转变成汇编代码如下：

```
0x01a3de1d: movb $0×0,0×1104800(%esi);0x01a3de24: lock addl $0×0,(%esp);
```

在生成汇编代码时会在 volatile 修饰的共享变量进行写操作的时候会多出 **Lock 前缀的指令**（具体的大家可以使用一些工具去看一下，这里我就只把结果说出来）。我们想这个**Lock** 指令肯定有神奇的地方，那么 Lock 前缀的指令在多核处理器下会发现什么事情了？主要有这两个方面的影响：

1. 将当前处理器缓存行的数据写回系统内存；
2. 这个写回内存的操作会使得其他CPU里缓存了该内存地址的数据无效

为了提高处理速度，处理器不直接和内存进行通信，而是先将系统内存的数据读到内部缓存（L1，L2或其他）后再进行操作，但操作完不知道何时会写到内存。如果对声明了volatile的变量进行写操作，JVM就会向处理器发送一条Lock前缀的指令，将这个变量所在缓存行的数据写回到系统内存。但是，就算写回到内存，如果其他处理器缓存的值还是旧的，再执行计算操作就会有问题。所以，在多处理器下，为了保证各个处理器的缓存是一致的，**就会实现缓存一致性协议**，**每个处理器通过嗅探在总线上传播的数据来检查自己缓存的值是不是过期了**，当处理器发现自己缓存行对应的内存地址被修改，就会将当前处理器的缓存行设置成无效状态，当处理器对这个数据进行修改操作的时候，会重新从系统内存中把数据读到处理器缓存里。

因此，经过分析，volatile 的实现原则如下：

1. Lock前缀的指令会引起处理器缓存写回内存；
2. 一个处理器的缓存回写到内存会导致其他处理器的缓存失效；
3. 当处理器发现本地缓存失效后，就会从内存中重读该变量数据，即可以获取当前最新值。

这样针对 volatile 变量通过这样的机制就使得每个线程都能获得该变量的最新值。

## 3、volatile 的 happens-before 关系

经过上面的分析，我们已经知道了volatile变量可以通过**缓存一致性协议**保证每个线程都能获得最新值，即满足数据的“可见性”。我们继续延续上一篇分析问题的方式（我一直认为思考问题的方式是属于自己，也才是最重要的，也在不断培养这方面的能力），我一直将并发分析的切入点分为**两个核心，三大性质**。两大核心：JMM内存模型（主内存和工作内存）以及happens-before；三条性质：原子性，可见性，有序性（关于三大性质的总结在以后得文章会和大家共同探讨）。废话不多说，先来看两个核心之一：volatile的happens-before关系。

在六条happens-before规则中有一条是：**volatile变量规则：对一个volatile域的写，happens-before于任意后续对这个volatile域的读。**下面我们结合具体的代码，我们利用这条规则推导下：

```java
public class VolatileExample {
    private int a = 0;
    private volatile boolean flag = false;
    public void writer(){
        a = 1;          //1
        flag = true;   //2
    }
    public void reader(){
        if(flag){      //3
            int i = a; //4
        }
    }
}
```

假设线程A执行writer()方法之后，线程B执行reader()方法。

上述happens-before关系的图形化表现形式如下：

 ![happens-before](./image/happens-before.jpg ':size=65%')

在上图中，每一个箭头链接的两个节点，代表了一个happens-before关系。黑色箭头表示程序顺序规则；橙色箭头表示volatile规则；蓝色箭头表示组合这些规则后提供的happens-before保证。

这里A线程写一个volatile变量后，B线程读同一个volatile变量。A线程在写volatile变量之前所有可见的共享变量，在B线程读同一个volatile变量后，将立即变得对B线程可见。

## 4、volatile的内存语义

还是按照**两个核心**的分析方式，分析完happens-before关系后我们现在就来进一步分析volatile的内存语义。

volatile写的内存语义如下：

> **当写一个volatile变量时，JMM会把该线程对应的本地内存中的共享变量值刷新到主内存。**

以上面示例程序VolatileExample为例，假设线程A首先执行writer()方法，随后线程B执行reader()方法，初始时两个线程的本地内存中的flag和a都是初始状态。图3-17是线程A执行volatile写后，共享变量的状态示意图。

 ![image-20220329150735822](./image/image-20220329150735822.png ':size=50%')

如图，线程A在写flag变量后，本地内存A中被线程A更新过的两个共享变量的值被刷新到主内存中。此时，本地内存A和主内存中的共享变量的值是一致的。

volatile读的内存语义如下：

> **当读一个volatile变量时，JMM会把该线程对应的本地内存置为无效。线程接下来将从主内存中读取共享变量。**

图3-18为线程B读同一个volatile变量后，共享变量的状态示意图。

 ![image-20220329150922305](./image/image-20220329150922305.png ':size=50%')

如图所示，在读flag变量后，本地内存B包含的值已经被置为无效。此时，线程B必须从主内存中读取共享变量。线程B的读取操作将导致本地内存B与主内存中的共享变量的值变成一致。

如果我们把volatile写和volatile读两个步骤综合起来看的话，在读线程B读一个volatile变量后，写线程A在写这个volatile变量之前所有可见的共享变量的值都将立即变得对读线程B可见。

下面对volatile写和volatile读的内存语义做个**总结**：

- 线程A写一个volatile变量，实质上是线程A向接下来将要读这个volatile变量的某个线程发出了（其对共享变量所做修改的）消息。
- 线程B读一个volatile变量，实质上是线程B接收了之前某个线程发出的（在写这个volatile变量之前对共享变量所做修改的）消息。
- 线程A写一个volatile变量，随后线程B读这个volatile变量，这个过程实质上是线程A通过主内存向线程B发送消息。

## 5、volatile内存语义的实现

我们都知道，为了性能优化，JMM在不改变正确语义的前提下，会允许编译器和处理器对指令序列进行重排序，那如果想阻止重排序要怎么办了？答案是可以添加内存屏障。

> **内存屏障**

JMM内存屏障分为四类见下图

 ![image-20220329151324317](./image/image-20220329151324317.png ':size=70%')

java编译器会在生成指令系列时在适当的位置会插入内存屏障指令来禁止特定类型的处理器重排序。为了实现volatile的内存语义，JMM会限制特定类型的编译器和处理器重排序，JMM会针对编译器制定volatile重排序规则表：

 ![image-20220329151405399](./image/image-20220329151405399.png ':size=70%')

举例来说，第三行最后一个单元格的意思是：在程序中，当第一个操作为普通变量的读或写时，如果第二个操作为volatile写，则编译器不能重排序这两个操作。 从上图可以看出：

- 当第二个操作是volatile写时，不管第一个操作是什么，都不能重排序。这个规则确保volatile写之前的操作不会被编译器重排序到volatile写之后。
- 当第一个操作是volatile读时，不管第二个操作是什么，都不能重排序。这个规则确保volatile读之后的操作不会被编译器重排序到volatile读之前。
- 当第一个操作是volatile写，第二个操作是volatile读时，不能重排序。

为了实现volatile的内存语义，编译器在生成字节码时，会在指令序列中插入内存屏障来禁止特定类型的处理器重排序。对于编译器来说，发现一个最优布置来最小化插入屏障的总数几乎不可能。为此，JMM采取保守策略。下面是基于保守策略的JMM内存屏障插入策略：

- 在每个**volatile写**操作的**前面**插入一个StoreStore屏障。
- 在每个**volatile写**操作的**后面**插入一个StoreLoad屏障。
- 在每个**volatile读**操作的**后面**插入一个LoadLoad屏障。
- 在每个**volatile读**操作的**后面**插入一个LoadStore屏障。

需要注意的是：volatile写是在前面和后面**分别插入内存屏障**，而volatile读操作是在**后面插入两个内存屏障**。上述内存屏障插入策略非常保守，但它可以保证在任意处理器平台，任意的程序中都能得到正确的volatile内存语义。

内存屏障在这里的语义可以理解为：

- **StoreStore屏障**：禁止上面的普通写和下面的volatile写重排序；
- **StoreLoad屏障**：防止上面的volatile写与下面可能有的volatile读/写重排序
- **LoadLoad屏障**：禁止下面所有的普通读操作和上面的volatile读重排序
- **LoadStore屏障**：禁止下面所有的普通写操作和上面的volatile读重排序

如下图：

 ![image-20220329164851674](./image/image-20220329164851674.png ':size=60%')

 ![image-20220329164911472](./image/image-20220329164911472.png ':size=60%')

上述volatile写和volatile读的内存屏障插入策略非常保守。在实际执行时，只要不改变volatile写-读的内存语义，编译器可以根据具体情况省略不必要的屏障。

## 6、一个例子

我们现在已经理解volatile的精华了，再重新认识一下以下代码：

```java
public class VolatileDemo {
    private static volatile boolean isOver = false;

    public static void main(String[] args) {
        Thread thread = new Thread(new Runnable() {
            @Override
            public void run() {
                while (!isOver) ;
            }
        });
        thread.start();
        try {
            Thread.sleep(500);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
        isOver = true;
    }
}
```

现在已经**将isOver设置成了volatile变量**，这样在main线程中将isOver改为了true后，thread的工作内存该变量值就会失效，从而需要再次从主内存中读取该值，现在能够读出isOver最新值为true从而能够结束在thread里的死循环，从而能够顺利停止掉thread线程。

