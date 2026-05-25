using System;

namespace BPlusGenerated
{
    public abstract class State
    {
        public virtual void Enter() {}
        public virtual void Exit() {}
        public virtual State Always() => null;
        public static void print(object s) => Console.WriteLine(s);
    }

    public static class Context
    {
        public static int max_score { get; set; } = 10;
    }

    public class Menu : State
    {
        public override void Enter()
        {
            print("Menu: press start");
        }
        public override State OnStart()
        {
            return new Game();
        }
    }

    public class Game : State
    {
        public int score { get; set; } = 0;
        public int lives { get; set; } = 3;

        public override void Enter()
        {
            print("Game started!");
        }
        public override State OnHit()
        {
            score = score + 1;
            print("Score +1");
            if (lives > 0)
                return new Game();
            return null;
        }
        public override State OnDie()
        {
            if (lives <= 1)
                return new GameOver();
            return null;
        }
        public override State OnDie()
        {
            lives = lives - 1;
            print("Lost a life");
            if (lives > 1)
                return new Game();
            return null;
        }
        public override State OnWin()
        {
            if (score >= max_score)
                return new Victory();
            return null;
        }
    }

    public class GameOver : State
    {
        public override void Enter()
        {
            print("Game Over!");
        }
        public override State OnRestart()
        {
            return new Menu();
        }
    }

    public class Victory : State
    {
        public override void Enter()
        {
            print("You Win!");
        }
        public override State OnRestart()
        {
            return new Menu();
        }
    }


    class Program
    {
        static int Main(string[] args)
        {
            Console.WriteLine("Game logic compiled successfully!");
            return 0;
        }
    }
}
